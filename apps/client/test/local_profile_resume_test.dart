import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';

import 'dart:convert';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_profile_resume_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class MemoryResumeStore implements LocalProfileResumeStore {
  String? value;
  bool fail = false;
  bool dropWrites = false;
  bool failClear = false;
  void Function()? onWrite;
  @override
  Future<String?> read() async {
    if (fail) throw StateError('unavailable');
    return value;
  }

  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('unavailable');
    if (!dropWrites) this.value = value;
    onWrite?.call();
  }

  @override
  Future<void> clear() async {
    if (fail || failClear) throw StateError('unavailable');
    value = null;
  }
}

class DeleteOnlySecureStorage implements FlutterSecureStorage {
  bool fail = false;
  bool deleted = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #delete) {
      if (fail) return Future<void>.error(StateError('delete unavailable'));
      deleted = true;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late VaultCrypto crypto;
  late LocalProfileCatalog catalog;
  late LocalProfileService service;
  late MemoryResumeStore store;
  late MemoryResumeStore deviceStore;
  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });
  setUp(() {
    catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    store = MemoryResumeStore();
    deviceStore = MemoryResumeStore();
    service = LocalProfileService(
      catalog: catalog,
      crypto: crypto,
      resumeStore: store,
      deviceKeyStore: deviceStore,
    );
  });
  tearDown(() async {
    await catalog.close();
  });
  test(
    'native revoke tolerates marker failure when secure delete succeeds',
    () async {
      final secure = DeleteOnlySecureStorage();
      final native = NativeLocalProfileResumeStore(
        storage: secure,
        setRevoked: (_, _) async => throw StateError('marker unavailable'),
      );
      await native.clear();
      expect(secure.deleted, isTrue);
    },
  );
  test('native revoke tolerates secure failure with durable marker, rejects double failure', () async {
    final secure = DeleteOnlySecureStorage()..fail = true;
    var markerWritten = false;
    final native = NativeLocalProfileResumeStore(
      storage: secure,
      setRevoked: (_, value) async {
        markerWritten = value;
      },
    );
    await native.clear();
    expect(markerWritten, isTrue);
    final failed = NativeLocalProfileResumeStore(
      storage: secure,
      setRevoked: (_, _) async => throw StateError('marker unavailable'),
    );
    await expectLater(failed.clear(), throwsStateError);
    final manual = LocalProfileService(
      catalog: catalog,
      crypto: crypto,
      resumeStore: failed,
    );
    await expectLater(manual.forgetResume(), throwsStateError);
  });
  test('fresh service resumes exact authenticated keys after memory teardown; forget revokes', () async {
    final original = await service.create(
      password: 'correct horse battery staple',
    );
    final expectedKey = original.copyVaultKey();
    await service.remember(original);
    expect(store.value, isNot(contains('correct horse battery staple')));
    await original.lock();
    final restarted = LocalProfileService(
      catalog: catalog,
      crypto: crypto,
      resumeStore: store,
      deviceKeyStore: deviceStore,
    );
    final resumed = await restarted.tryResume();
    expect(resumed, isNotNull);
    expect(resumed!.record.profileId, original.record.profileId);
    final actualKey = resumed.copyVaultKey();
    expect(actualKey, expectedKey);
    actualKey.fillRange(0, actualKey.length, 0);
    expectedKey.fillRange(0, expectedKey.length, 0);
    await restarted.forgetResume();
    await resumed.lock();
    expect(await restarted.tryResume(), isNull);
  });
  testWidgets(
    'fresh launch opens decrypted hosts without chooser; manual lock revokes',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-resume-'),
      ))!;
      final vault = File('${directory.path}/vault.sqlite');
      LocalVaultDatabase? activeDatabase;
      Future<LocalVaultDatabase> open(
        UnlockedLocalProfile profile, {
        required LocalVaultOpenMode mode,
      }) async {
        final r = profile.record;
        return activeDatabase = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(vault),
          profileId: r.profileId,
          localDataDomainId: r.localDataDomainId,
          localVaultId: r.localVaultId,
          mode: mode,
        );
      }

      await tester.runAsync(() async {
        final original = await service.create(
          password: 'correct horse battery staple',
        );
        final database = await open(
          original,
          mode: LocalVaultOpenMode.createNew,
        );
        await LocalHostRepository(
          database: database,
          profile: original,
          crypto: crypto,
        ).createHost(
          const HostRecord(
            id: '11111111-1111-4111-8111-111111111111',
            name: 'Restored encrypted host',
            address: 'resume.example.test',
            username: 'demo',
          ),
        );
        await service.remember(original);
        await original.lock();
        await database.close();
      });
      final restarted = LocalProfileService(
        catalog: catalog,
        crypto: crypto,
        resumeStore: store,
        deviceKeyStore: deviceStore,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LocalProfileFlow(
            catalog: catalog,
            service: restarted,
            crypto: crypto,
            onExit: () {},
            databaseFactory: open,
          ),
        ),
      );
      // No selector may flash while secure resume is pending.
      expect(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        findsNothing,
      );
      for (
        var i = 0;
        i < 100 && find.text('Restored encrypted host').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Restored encrypted host'), findsWidgets);
      expect(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(
        store.value,
        isNotNull,
      ); // Ordinary window teardown preserves access.
      await tester.pumpWidget(
        MaterialApp(
          home: LocalProfileFlow(
            catalog: catalog,
            service: LocalProfileService(
              catalog: catalog,
              crypto: crypto,
              resumeStore: store,
              deviceKeyStore: deviceStore,
            ),
            crypto: crypto,
            onExit: () {},
            databaseFactory: open,
          ),
        ),
      );
      for (
        var i = 0;
        i < 100 && find.text('Restored encrypted host').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Restored encrypted host'), findsWidgets);
      await tester.tap(find.byTooltip('Host menu · click to open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_profile_lock')));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(store.value, isNull);
      expect(await restarted.tryResume(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await activeDatabase?.close();
        await directory.delete(recursive: true);
      });
    },
  );

  testWidgets(
    'clean install creates workspace and ordinary close reopens without chooser',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-resume-'),
      ))!;
      final vault = File('${directory.path}/vault.sqlite');
      LocalVaultDatabase? activeDatabase;
      Future<LocalVaultDatabase> open(
        UnlockedLocalProfile profile, {
        required LocalVaultOpenMode mode,
      }) async {
        final r = profile.record;
        return activeDatabase = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(vault),
          profileId: r.profileId,
          localDataDomainId: r.localDataDomainId,
          localVaultId: r.localVaultId,
          mode: mode,
        );
      }

      final restarted = LocalProfileService(
        catalog: catalog,
        crypto: crypto,
        resumeStore: store,
        deviceKeyStore: deviceStore,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LocalProfileFlow(
            autoCreateOnFirstLaunch: true,
            catalog: catalog,
            service: restarted,
            crypto: crypto,
            onExit: () {},
            databaseFactory: open,
          ),
        ),
      );
      // No selector may flash while secure resume is pending.
      expect(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        findsNothing,
      );
      for (
        var i = 0;
        i < 100 && find.text('No Hosts yet').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('No Hosts yet'), findsWidgets);
      expect(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(
        store.value,
        isNotNull,
      ); // Ordinary window teardown preserves access.
      await tester.pumpWidget(
        MaterialApp(
          home: LocalProfileFlow(
            autoCreateOnFirstLaunch: true,
            catalog: catalog,
            service: LocalProfileService(
              catalog: catalog,
              crypto: crypto,
              resumeStore: store,
              deviceKeyStore: deviceStore,
            ),
            crypto: crypto,
            onExit: () {},
            databaseFactory: open,
          ),
        ),
      );
      for (
        var i = 0;
        i < 100 && find.text('No Hosts yet').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('No Hosts yet'), findsWidgets);
      await tester.tap(find.byTooltip('Host menu · click to open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local_profile_lock')));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(store.value, isNull);
      expect(await restarted.tryResume(), isNull);
      expect(find.text('Open local workspace'), findsOneWidget);
      await tester.tap(find.text('Open local workspace'));
      for (
        var i = 0;
        i < 100 && find.text('No Hosts yet').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('No Hosts yet'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await activeDatabase?.close();
        await directory.delete(recursive: true);
      });
    },
  );

  testWidgets('secure storage failure keeps first launch outside workspace', (
    tester,
  ) async {
    store.dropWrites = true;
    var openedDatabase = false;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalProfileFlow(
          catalog: catalog,
          service: service,
          crypto: crypto,
          autoCreateOnFirstLaunch: true,
          onExit: () {},
          databaseFactory: (profile, {required mode}) async {
            openedDatabase = true;
            throw StateError('Should not open');
          },
        ),
      ),
    );
    for (
      var i = 0;
      i < 100 &&
          find
              .byKey(const ValueKey('local_profile_create_button'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(openedDatabase, isFalse);
    expect(find.text('No Hosts yet'), findsNothing);
    expect(
      find.byKey(const ValueKey('local_profile_create_button')),
      findsOneWidget,
    );
    expect(await tester.runAsync(() => catalog.list()), isEmpty);
    expect(store.value, isNull);
    expect(deviceStore.value, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'device bootstrap persists protected keys before creating catalog',
    () async {
      final profile = await service.createDeviceProtected();
      expect((await catalog.list()).single.profileId, profile.record.profileId);
      expect(store.value, isNotNull);
      await profile.lock();
      final resumed = await service.tryResume();
      expect(resumed?.record.profileId, profile.record.profileId);
      await resumed?.lock();
      final existing = await service.createDeviceProtected();
      expect(existing.record.profileId, profile.record.profileId);
      expect(existing.isNewlyCreated, isFalse);
      await existing.lock();
      expect(await catalog.list(), hasLength(1));
      await service.forgetResume();
      expect(await service.tryResume(), isNull);
      expect(await service.isDeviceManaged(profile.record.profileId), isTrue);
      final explicit = await service.unlockDeviceProfile(
        profile.record.profileId,
      );
      expect(explicit?.record.profileId, profile.record.profileId);
      await explicit?.lock();
      expect(store.value, isNull);
    },
  );

  test(
    'catalog publishes only after the Vault is ready while contenders wait',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var initializations = 0;
      final first = service.createDeviceProtected(
        initializeVault: (profile) async {
          initializations++;
          expect(await catalog.list(), isEmpty);
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      final second = service.createDeviceProtected(
        initializeVault: (_) async {
          initializations++;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await catalog.list(), isEmpty);
      release.complete();
      final profiles = await Future.wait([first, second]);
      expect(initializations, 1);
      expect(profiles.map((p) => p.record.profileId).toSet(), hasLength(1));
      for (final p in profiles) {
        await p.lock();
      }
    },
  );

  test('Vault initialization failure rolls back only staged keys before publication', () async {
    await expectLater(
      service.createDeviceProtected(
        initializeVault: (_) async {
          throw StateError('Vault initialization failed');
        },
      ),
      throwsStateError,
    );
    expect(await catalog.list(), isEmpty);
    expect(store.value, isNull);
    expect(deviceStore.value, isNull);
  });

  test('failed cleanup retains a protected recovery descriptor and blocks replacement', () async {
    deviceStore.failClear = true;
    await expectLater(
      service.createDeviceProtected(
        initializeVault: (_) async {
          throw StateError('Vault initialization failed');
        },
      ),
      throwsStateError,
    );
    expect(await catalog.list(), isEmpty);
    final retained = deviceStore.value;
    expect((jsonDecode(retained!) as Map)['pending_profile'], isA<Map>());
    await expectLater(service.createDeviceProtected(), throwsStateError);
    expect(deviceStore.value, retained);
  });

  test(
    'rollback does not delete a different profile key after readback mismatch',
    () async {
      final foreign = jsonEncode({
        'profile_id': 'another-profile',
        'umk': 'protected',
      });
      store.onWrite = () {
        store.value = foreign;
        deviceStore.value = foreign;
      };
      await expectLater(service.createDeviceProtected(), throwsStateError);
      expect(await catalog.list(), isEmpty);
      expect(store.value, foreign);
      expect(deviceStore.value, foreign);
    },
  );

  test(
    'simultaneous native bootstraps create exactly one recoverable profile',
    () async {
      final other = LocalProfileService(
        catalog: catalog,
        crypto: crypto,
        resumeStore: store,
        deviceKeyStore: deviceStore,
      );
      final profiles = await Future.wait([
        service.createDeviceProtected(),
        other.createDeviceProtected(),
      ]);
      expect(await catalog.list(), hasLength(1));
      expect(profiles.map((p) => p.record.profileId).toSet(), hasLength(1));
      expect(profiles.where((p) => p.isNewlyCreated), hasLength(1));
      for (final p in profiles) {
        await p.lock();
      }
      await service.forgetResume();
      await expectLater(other.createDeviceProtected(), throwsStateError);
      final explicit = await other.unlockDeviceProfile(
        profiles.first.record.profileId,
      );
      expect(explicit, isNotNull);
      await explicit?.lock();
    },
  );

  test(
    'missing device key never replaces an existing random password profile',
    () async {
      final profile = await service.createDeviceProtected();
      final original = deviceStore.value;
      await profile.lock();
      deviceStore.value = null;
      await expectLater(service.createDeviceProtected(), throwsStateError);
      expect((await catalog.list()).single.profileId, profile.record.profileId);
      expect(deviceStore.value, isNull);
      deviceStore.value = original;
    },
  );

  test(
    'temporary device storage failure preserves the only persistent unlock key',
    () async {
      final profile = await service.createDeviceProtected();
      await profile.lock();
      await service.forgetResume();
      final retained = deviceStore.value;
      deviceStore.fail = true;
      expect(
        await service.unlockDeviceProfile(profile.record.profileId),
        isNull,
      );
      expect(deviceStore.value, retained);
      deviceStore.fail = false;
      final explicit = await service.unlockDeviceProfile(
        profile.record.profileId,
      );
      expect(explicit, isNotNull);
      await explicit?.lock();
    },
  );

  test(
    'device key write or readback failure leaves both stores and catalog empty',
    () async {
      for (final dropped in [false, true]) {
        deviceStore.fail = !dropped;
        deviceStore.dropWrites = dropped;
        await expectLater(service.createDeviceProtected(), throwsStateError);
        expect(await catalog.list(), isEmpty);
        expect(store.value, isNull);
        expect(deviceStore.value, isNull);
      }
    },
  );

  test(
    'device bootstrap fails closed without leaving a passwordless catalog',
    () async {
      store.fail = true;
      await expectLater(service.createDeviceProtected(), throwsStateError);
      expect(await catalog.list(), isEmpty);
      store.fail = false;
      final profile = await service.createDeviceProtected();
      await profile.lock();
    },
  );

  test(
    'corrupt wrong-profile wrong-key and stale records fail closed',
    () async {
      final original = await service.create(
        password: 'correct horse battery staple',
      );
      await service.remember(original);
      final good = store.value!;
      for (final change in <String, Object>{
        'profile_id': '11111111-1111-4111-8111-111111111111',
        'fingerprint': 'stale',
        'umk': base64Encode(List.filled(32, 0)),
        'version': 2,
      }.entries) {
        final data = jsonDecode(good) as Map<String, dynamic>;
        data[change.key] = change.value;
        store.value = jsonEncode(data);
        expect(await service.tryResume(), isNull, reason: change.key);
        expect(store.value, isNull);
      }
      store.value = '{broken';
      expect(await service.tryResume(), isNull);
      await original.lock();
    },
  );
  test('secure store failure leaves manual use available', () async {
    store.fail = true;
    final original = await service.create(
      password: 'correct horse battery staple',
    );
    await service.remember(original);
    expect(await service.tryResume(), isNull);
    await original.lock();
    final manual = await service.unlock(
      profileId: original.record.profileId,
      password: 'correct horse battery staple',
    );
    expect(manual.isLocked, isFalse);
    await manual.lock();
  });
}
