import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/credential_visibility/credential_escrow_crypto.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_ack_store.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/credential_visibility_fakes.dart';
import 'support/credential_visibility_fixtures.dart';

/// Waits for the refresh the service schedules on its own.
Future<void> settle(CredentialVisibilityService service) async {
  await pumpEventQueue();
  for (var i = 0; i < 100 && service.refreshing; i++) {
    await pumpEventQueue();
  }
}

void main() {
  late SodiumSumo sodium;
  late EscrowTestInstance instance;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    sodium = await SodiumSumoInit.init();
    instance = EscrowTestInstance(sodium);
  });

  test('without the server capability the service stays inert', () async {
    final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
    final app = cvApp(
      sodium,
      server.api,
      pinnedKey: instance.signingPublicKey,
      capability: false,
    );
    final service = CredentialVisibilityService(
      app,
      ackStore: MemoryCredentialVisibilityAckStore(),
    );
    await service.refresh();
    await pumpEventQueue();
    expect(service.available, isFalse);
    expect(service.mode, isNull);
    expect(service.pendingNotice, isNull);
    expect(server.requests, isEmpty);
    service.dispose();
    app.dispose();
  });

  test(
    'admin-visible pending: deposits every held key to the verified key',
    () async {
      final escrow = sodium.crypto.box.keyPair();
      final descriptor = instance.descriptor(
        keyId: escrowKeyId,
        publicKey: escrow.publicKey,
      );
      final server = FakeCredentialVisibilityServer(
        cvStatus(
          mode: 'admin_visible',
          escrowStatus: 'pending',
          key: descriptor,
          changedAt: '2026-11-13T09:00:00Z',
          missing: [
            {'vault_id': escrowVaultId, 'key_epoch': 1},
            {'vault_id': escrowVaultId, 'key_epoch': 2},
            // Not held by this device: skipped, left for another device.
            {'vault_id': escrowSecondVaultId, 'key_epoch': 1},
          ],
        ),
      );
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      final keys = {
        '$escrowVaultId:1': Uint8List.fromList(List.filled(32, 1)),
        '$escrowVaultId:2': Uint8List.fromList(List.filled(32, 2)),
      };
      final handedOut = <Uint8List>[];
      final service = CredentialVisibilityService(
        app,
        ackStore: MemoryCredentialVisibilityAckStore(),
        vaultKeyLookup: (vaultId, epoch) {
          final key = keys['$vaultId:$epoch'];
          if (key == null) return null;
          final copy = Uint8List.fromList(key);
          handedOut.add(copy);
          return copy;
        },
      );
      await settle(service);
      expect(server.deposits, hasLength(2));
      expect(service.depositedThisScope, 2);
      expect(service.lastError, isNull);
      expect(service.status!.escrowStatus, CredentialEscrowStatus.pending);
      expect(service.status!.missing.single.vaultId, escrowSecondVaultId);
      // Copies handed to the service are zeroed after sealing.
      for (final copy in handedOut) {
        expect(copy.every((byte) => byte == 0), isTrue);
      }
      final verified = verifyEscrowKeyDescriptor(
        sodium,
        descriptor: descriptor,
        instanceId: escrowInstanceId,
        pinnedInstanceSigningKey: instance.signingPublicKey,
      );
      for (final deposit in server.deposits) {
        expect(deposit['key_id'], escrowKeyId);
        final epoch = deposit['key_epoch'] as int;
        final opened = openEscrowDeposit(
          sodium,
          key: verified,
          secretKey: escrow.secretKey,
          instanceId: escrowInstanceId,
          vaultId: deposit['vault_id'] as String,
          keyEpoch: epoch,
          sealed: deposit['sealed'] as String,
          signature: deposit['signature'] as String,
          depositorSigningPublicKey: app.identity!.signingPublicKey,
        );
        expect(opened, keys['$escrowVaultId:$epoch']);
      }
      // Status → deposits → status re-read.
      expect(server.requests.map((r) => r.method), [
        'GET',
        'PUT',
        'PUT',
        'GET',
      ]);
      service.dispose();
      app.dispose();
      escrow.dispose();
    },
  );

  test(
    'never deposits to a key the pinned instance key did not sign',
    () async {
      final escrow = sodium.crypto.box.keyPair();
      final rogue = EscrowTestInstance(sodium);
      final server = FakeCredentialVisibilityServer(
        cvStatus(
          mode: 'admin_visible',
          escrowStatus: 'pending',
          key: rogue.descriptor(
            keyId: escrowKeyId,
            publicKey: escrow.publicKey,
          ),
          missing: [
            {'vault_id': escrowVaultId, 'key_epoch': 1},
          ],
        ),
      );
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      var lookups = 0;
      final service = CredentialVisibilityService(
        app,
        ackStore: MemoryCredentialVisibilityAckStore(),
        vaultKeyLookup: (_, _) {
          lookups++;
          return Uint8List(32);
        },
      );
      await settle(service);
      expect(service.escrowKeyRejected, isTrue);
      expect(lookups, 0);
      expect(server.deposits, isEmpty);
      expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
      service.dispose();
      app.dispose();
      escrow.dispose();
    },
  );

  test(
    'deposit failures are recorded, not thrown, and stop on key change',
    () async {
      final escrow = sodium.crypto.box.keyPair();
      final server =
          FakeCredentialVisibilityServer(
              cvStatus(
                mode: 'admin_visible',
                escrowStatus: 'pending',
                key: instance.descriptor(
                  keyId: escrowKeyId,
                  publicKey: escrow.publicKey,
                ),
                missing: [
                  {'vault_id': escrowVaultId, 'key_epoch': 1},
                  {'vault_id': escrowVaultId, 'key_epoch': 2},
                ],
              ),
            )
            ..depositFailure = (
              status: 409,
              body: {
                'error': {
                  'code': 'CREDENTIAL_ESCROW_KEY_MISMATCH',
                  'message': 'The escrow key changed.',
                  'request_id': 'r',
                },
              },
            );
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      final service = CredentialVisibilityService(
        app,
        ackStore: MemoryCredentialVisibilityAckStore(),
        vaultKeyLookup: (_, _) => Uint8List.fromList(List.filled(32, 9)),
      );
      await settle(service);
      expect(
        service.lastError,
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'CREDENTIAL_ESCROW_KEY_MISMATCH',
        ),
      );
      // One PUT, then stop; the status is re-read for the UI.
      expect(server.requests.where((r) => r.method == 'PUT'), hasLength(1));
      expect(server.requests.last.method, 'GET');
      service.dispose();
      app.dispose();
      escrow.dispose();
    },
  );

  test(
    'private mode: no deposits, first sign-in notice, acknowledgement persists',
    () async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
        policy: {
          'credential_visibility': {'mode': 'private', 'changed_at': null},
        },
      );
      final store = MemoryCredentialVisibilityAckStore();
      final service = CredentialVisibilityService(app, ackStore: store);
      await pumpEventQueue();
      await service.refresh();
      expect(service.mode, CredentialVisibilityMode.private);
      expect(service.adminVisible, isFalse);
      expect(service.pendingNotice, CredentialVisibilityNotice.private);
      await service.acknowledge();
      expect(service.pendingNotice, isNull);
      expect(store.writes, 1);
      expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
      service.dispose();

      // A new service on this device (restart) reads the stored ack.
      final again = CredentialVisibilityService(app, ackStore: store);
      await pumpEventQueue();
      await again.refresh();
      expect(again.pendingNotice, isNull);

      // The admin switches the account: a new changed_at needs a new notice.
      server.status = cvStatus(
        mode: 'admin_visible',
        escrowStatus: 'no_key',
        changedAt: '2026-11-13T12:00:00Z',
      );
      await again.refresh();
      expect(
        again.pendingNotice,
        CredentialVisibilityNotice.switchedToAdminVisible,
      );
      await again.acknowledge();
      expect(again.pendingNotice, isNull);

      // And back to private: the "switched to private" warning.
      server.status = cvStatus(
        mode: 'private',
        changedAt: '2026-11-13T13:00:00Z',
      );
      await again.refresh();
      expect(again.pendingNotice, CredentialVisibilityNotice.switchedToPrivate);
      again.dispose();
      app.dispose();
    },
  );

  test(
    'first sign-in while admin-visible shows the admin-visible notice',
    () async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(mode: 'admin_visible', escrowStatus: 'no_key'),
      );
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      final service = CredentialVisibilityService(
        app,
        ackStore: MemoryCredentialVisibilityAckStore(),
      );
      await pumpEventQueue();
      await service.refresh();
      expect(service.adminVisible, isTrue);
      expect(service.pendingNotice, CredentialVisibilityNotice.adminVisible);
      service.dispose();
      app.dispose();
    },
  );

  test('signing out clears the scope and its status', () async {
    final server = FakeCredentialVisibilityServer(
      cvStatus(mode: 'admin_visible', escrowStatus: 'no_key'),
    );
    final app = cvApp(sodium, server.api, pinnedKey: instance.signingPublicKey);
    final service = CredentialVisibilityService(
      app,
      ackStore: MemoryCredentialVisibilityAckStore(),
    );
    await service.refresh();
    expect(service.status, isNotNull);
    app.session = null;
    app.account = null;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    app.notifyListeners();
    await pumpEventQueue();
    expect(service.available, isFalse);
    expect(service.status, isNull);
    expect(service.mode, isNull);
    service.dispose();
    app.dispose();
  });

  // The service's own triggers: every test changes the controller the way
  // the app does and lets the service react, without calling refresh().
  group('automatic triggers', () {
    late KeyPair escrow;
    late Map<String, dynamic> descriptor;

    setUp(() {
      escrow = sodium.crypto.box.keyPair();
      descriptor = instance.descriptor(
        keyId: escrowKeyId,
        publicKey: escrow.publicKey,
      );
    });
    tearDown(() => escrow.dispose());

    Map<String, dynamic> status(List<Map<String, Object>> missing) => cvStatus(
      mode: 'admin_visible',
      escrowStatus: missing.isEmpty ? 'complete' : 'pending',
      key: descriptor,
      changedAt: '2026-11-13T09:00:00Z',
      missing: missing,
    );

    VaultDescriptor vault(String id, {int epoch = 1, int membership = 1}) =>
        VaultDescriptor.fromJson({
          'vault_id': id,
          'role': 'owner',
          'active_key_epoch': epoch,
          'membership_version': membership,
        });

    Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

    /// A bound service whose Vault keys come from [keys].
    (CvTestAppController, CredentialVisibilityService) bind(
      FakeCredentialVisibilityServer server,
      Map<String, Uint8List> keys, {
      List<VaultDescriptor> vaults = const [],
      DateTime Function()? clock,
    }) {
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      )..testVaults = vaults;
      final service = CredentialVisibilityService(
        app,
        ackStore: MemoryCredentialVisibilityAckStore(),
        clock: clock,
        vaultKeyLookup: (vaultId, epoch) {
          final held = keys['$vaultId:$epoch'];
          return held == null ? null : Uint8List.fromList(held);
        },
      );
      return (app, service);
    }

    List<String> calls(FakeCredentialVisibilityServer server) => [
      for (final request in server.requests) request.method,
    ];

    test(
      'a new or newly shared Vault deposits; an equal list does not',
      () async {
        final server = FakeCredentialVisibilityServer(status(const []));
        final keys = {'$escrowVaultId:1': key(1)};
        final (app, service) = bind(
          server,
          keys,
          vaults: [vault(escrowVaultId)],
        );
        await settle(service);
        expect(calls(server), ['GET'], reason: 'complete: nothing to deposit');

        // A new list with the same Vaults, epochs and memberships.
        app.testVaults = [vault(escrowVaultId)];
        app.emitChange();
        await settle(service);
        expect(calls(server), ['GET']);

        // An accepted share adds a Vault the server now requires.
        server.status = status([
          {'vault_id': escrowSecondVaultId, 'key_epoch': 1},
        ]);
        keys['$escrowSecondVaultId:1'] = key(2);
        app.testVaults = [vault(escrowVaultId), vault(escrowSecondVaultId)];
        app.emitChange();
        await settle(service);
        expect(calls(server), ['GET', 'GET', 'PUT', 'GET']);
        expect(server.deposits.single['vault_id'], escrowSecondVaultId);
        expect(server.deposits.single['key_epoch'], 1);
        expect(service.status!.escrowStatus, CredentialEscrowStatus.complete);
        service.dispose();
        app.dispose();
      },
    );

    test('a key rotation or membership change re-checks escrow', () async {
      final server = FakeCredentialVisibilityServer(status(const []));
      final keys = {'$escrowVaultId:1': key(1)};
      final (app, service) = bind(server, keys, vaults: [vault(escrowVaultId)]);
      await settle(service);
      expect(calls(server), ['GET']);

      // Rotation to epoch 2: the new epoch is deposited.
      server.status = status([
        {'vault_id': escrowVaultId, 'key_epoch': 2},
      ]);
      keys['$escrowVaultId:2'] = key(2);
      app.testVaults = [vault(escrowVaultId, epoch: 2)];
      app.emitChange();
      await settle(service);
      expect(calls(server), ['GET', 'GET', 'PUT', 'GET']);
      expect(server.deposits.single['key_epoch'], 2);

      // A membership version change alone re-reads the status.
      app.testVaults = [vault(escrowVaultId, epoch: 2, membership: 2)];
      app.emitChange();
      await settle(service);
      expect(calls(server), ['GET', 'GET', 'PUT', 'GET', 'GET']);
      service.dispose();
      app.dispose();
    });

    test('unlocking re-checks escrow; locking does not', () async {
      final server = FakeCredentialVisibilityServer(status(const []));
      final keys = <String, Uint8List>{};
      final (app, service) = bind(server, keys, vaults: [vault(escrowVaultId)]);
      await settle(service);
      expect(calls(server), ['GET']);

      app.workspaceLocked = true;
      app.emitChange();
      await settle(service);
      expect(calls(server), ['GET'], reason: 'locking never contacts');

      // While locked the admin switched the account; unlocking makes this
      // device's Vault keys available again.
      server.status = status([
        {'vault_id': escrowVaultId, 'key_epoch': 1},
      ]);
      keys['$escrowVaultId:1'] = key(1);
      app.workspaceLocked = false;
      app.emitChange();
      await settle(service);
      expect(calls(server), ['GET', 'GET', 'PUT', 'GET']);
      expect(server.deposits, hasLength(1));
      service.dispose();
      app.dispose();
    });

    test(
      'a completed sync retries while pending or failed, else when stale',
      () async {
        var now = DateTime.utc(2026, 11, 13, 10);
        final server = FakeCredentialVisibilityServer(
          status([
            {'vault_id': escrowVaultId, 'key_epoch': 1},
          ]),
        );
        final keys = <String, Uint8List>{};
        final (app, service) = bind(
          server,
          keys,
          vaults: [vault(escrowVaultId)],
          clock: () => now,
        );
        await settle(service);
        // Pending, but this device does not hold the key (yet).
        expect(calls(server), ['GET']);
        expect(service.status!.escrowStatus, CredentialEscrowStatus.pending);

        Future<void> synced() async {
          app.lastSuccessfulSyncAt = now;
          now = now.add(const Duration(seconds: 1));
          app.emitChange();
          await settle(service);
        }

        await synced();
        expect(calls(server), ['GET', 'GET'], reason: 'retry while pending');

        // The sync delivered the key: the retry deposits it.
        keys['$escrowVaultId:1'] = key(1);
        await synced();
        expect(calls(server), ['GET', 'GET', 'GET', 'PUT', 'GET']);
        expect(service.status!.escrowStatus, CredentialEscrowStatus.complete);

        // Complete and fresh: syncs do not contact the endpoint.
        await synced();
        await synced();
        expect(calls(server), hasLength(5));

        // Stale after statusMaxAge: one refresh, which fails.
        now = now.add(service.statusMaxAge);
        server.status = {'unexpected': true};
        await synced();
        expect(calls(server), hasLength(6));
        expect(service.lastError, isA<FormatException>());

        // After a failure every completed sync retries until it succeeds.
        server.status = status(const []);
        await synced();
        expect(calls(server), hasLength(7));
        expect(service.lastError, isNull);
        await synced();
        expect(calls(server), hasLength(7));
        expect(server.deposits, hasLength(1));
        service.dispose();
        app.dispose();
      },
    );
  });

  group('vault key selection for escrow', () {
    Uint8List key(int fill, [int length = 32]) =>
        Uint8List.fromList(List.filled(length, fill));

    test('returns a private copy only for one agreeing 32-byte key', () {
      final held = key(7);
      final selected = selectEscrowVaultKey({
        '1:1': held,
        '1:2': key(7),
        '2:2': key(9),
      }, 1)!;
      expect(selected, key(7));
      selected.fillRange(0, 32, 0);
      expect(held, key(7), reason: 'the controller copy is untouched');
      expect(selectEscrowVaultKey({'2:2': key(9)}, 2), key(9));
    });

    test('rejects disagreeing copies, wrong lengths and other epochs', () {
      expect(selectEscrowVaultKey({'1:1': key(1), '1:2': key(2)}, 1), isNull);
      expect(selectEscrowVaultKey({'1:1': key(1, 31)}, 1), isNull);
      expect(
        selectEscrowVaultKey({'1:1': key(1), '1:2': key(1, 33)}, 1),
        isNull,
      );
      // '1:' must never match '11:' (or the other way round).
      expect(selectEscrowVaultKey({'11:1': key(3)}, 1), isNull);
      expect(selectEscrowVaultKey({'1:1': key(3)}, 11), isNull);
      expect(selectEscrowVaultKey({'11:1': key(3)}, 11), key(3));
      expect(selectEscrowVaultKey({'2:1': key(3)}, 1), isNull);
      expect(selectEscrowVaultKey(const {}, 1), isNull);
    });

    test('the controller hook holds nothing before a Vault is opened', () {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      expect(app.copyVaultKeyForCredentialEscrow(escrowVaultId, 1), isNull);
      app.dispose();
    });
  });

  test('ack records round-trip and tolerate junk', () {
    const ack = CredentialVisibilityAck(
      mode: CredentialVisibilityMode.adminVisible,
      changedAt: '2026-11-13T12:00:00Z',
    );
    final parsed = CredentialVisibilityAck.tryParse(jsonEncode(ack.toJson()))!;
    expect(parsed.mode, ack.mode);
    expect(parsed.changedAt, ack.changedAt);
    expect(CredentialVisibilityAck.tryParse('nope'), isNull);
    expect(CredentialVisibilityAck.tryParse('{"version":2}'), isNull);
    expect(CredentialVisibilityAck.tryParse(null), isNull);
  });
}
