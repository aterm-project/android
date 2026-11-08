import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverGeneration = '77777777-7777-4777-8777-777777777777';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'pull resolves a record signed by another Vault member device',
    () async {
      final own = DeviceIdentity.create(sodium);
      final remoteMember = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      const serverSpaceId = '11111111-1111-4111-8111-111111111111';
      const vaultId = '22222222-2222-4222-8222-222222222222';
      const recordId = '33333333-3333-4333-8333-333333333333';
      final envelope = await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: recordId,
        baseRevisionId: null,
        deviceId: remoteMember.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': recordId,
          'type': 'host',
          'name': 'Member written host',
          'address': '10.2.3.4',
          'username': 'ops',
          '_manifest': {
            'object_refs': [
              '40000000-0000-4000-8000-000000000001',
              '50000000-0000-4000-8000-000000000002',
            ],
          },
        },
        identity: remoteMember,
      );
      final api = _DirectoryApiClient(
        own: own,
        remoteMember: remoteMember,
        envelope: envelope,
        includeRemoteMember: true,
      );
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: crypto,
        identity: own,
        serverSpaceId: serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: Uint8List.fromList(key),
      );

      final result = await repository.synchronize();
      expect(result.receivedCount, 1);
      expect(await database.countPending(vaultId), 0);
      final records = await repository.loadRecords();
      expect(records, hasLength(1));
      expect(records.single['name'], 'Member written host');
      expect(records.single['_record_id'], recordId);
      expect(
        (records.single['_manifest'] as Map<String, dynamic>)['object_refs'],
        [
          '40000000-0000-4000-8000-000000000001',
          '50000000-0000-4000-8000-000000000002',
        ],
      );
      final cachedEnvelope = (await database.cachedEnvelopes(
        vaultId,
        instanceId: _instanceId,
        serverSpaceId: serverSpaceId,
      )).single;
      expect(
        (jsonDecode(cachedEnvelope.envelopeJson)['header']
            as Map)['object_refs'],
        (envelope['header'] as Map)['object_refs'],
      );

      await database.close();
      api.close();
      own.dispose();
      remoteMember.dispose();
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'membership key retirement waits for an in-flight multi-row decrypt',
    () async {
      final own = DeviceIdentity.create(sodium);
      final remoteMember = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final sharedVersionKey = Uint8List.fromList(key);
      final crypto = VaultCrypto(sodium);
      final gatedCrypto = _GatedDecryptVaultCrypto(sodium);
      const serverSpaceId = '11111111-1111-4111-8111-111111111111';
      const vaultId = '22222222-2222-4222-8222-222222222222';
      const recordIds = [
        '33333333-3333-4333-8333-333333333333',
        '44444444-4444-4444-8444-444444444444',
      ];
      final envelopes = <Map<String, Object?>>[];
      for (var index = 0; index < recordIds.length; index++) {
        envelopes.add(
          await crypto.encryptRecord(
            vaultKey: key,
            serverSpaceId: serverSpaceId,
            vaultId: vaultId,
            recordId: recordIds[index],
            baseRevisionId: null,
            deviceId: remoteMember.deviceId,
            deviceSequence: '${index + 1}',
            keyEpoch: '1',
            membershipVersion: '1',
            operation: 'create',
            plaintext: {
              'id': recordIds[index],
              'type': 'host',
              'name': 'Host $index',
            },
            identity: remoteMember,
          ),
        );
      }
      for (var index = 0; index < envelopes.length; index++) {
        final header = envelopes[index]['header']! as Map<String, dynamic>;
        await database.storeRemoteEnvelope(
          vaultId: vaultId,
          recordId: recordIds[index],
          revisionId: header['revision_id'] as String,
          envelope: envelopes[index],
          commitSeq: '${index + 1}',
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: serverSpaceId,
        );
      }
      final api = _DirectoryApiClient(
        own: own,
        remoteMember: remoteMember,
        envelope: envelopes.first,
        includeRemoteMember: true,
      );
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: gatedCrypto,
        identity: own,
        serverSpaceId: serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: Uint8List.fromList(key),
        vaultKeysByVersion: {'1:1': sharedVersionKey},
      );

      try {
        final loading = repository.loadRecords();
        await gatedCrypto.firstDecryptStarted.future;
        var retired = false;
        final retirement = repository.retireAndWaitForKeyOperations().then(
          (_) => retired = true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(retired, isFalse);
        expect(sharedVersionKey.any((byte) => byte != 0), isTrue);

        gatedCrypto.allowFirstDecrypt.complete();
        final records = await loading;
        await retirement;

        expect(records, hasLength(2));
        expect(
          records.map((record) => record['_record_id']).toSet(),
          recordIds.toSet(),
        );
        expect(retired, isTrue);
        sharedVersionKey.fillRange(0, sharedVersionKey.length, 0);
        expect(sharedVersionKey.every((byte) => byte == 0), isTrue);
        await expectLater(repository.loadRecords(), throwsA(isA<StateError>()));
      } finally {
        if (!gatedCrypto.allowFirstDecrypt.isCompleted) {
          gatedCrypto.allowFirstDecrypt.complete();
        }
        await database.close();
        api.close();
        own.dispose();
        remoteMember.dispose();
        key.fillRange(0, key.length, 0);
        sharedVersionKey.fillRange(0, sharedVersionKey.length, 0);
      }
    },
  );

  test(
    'second-device sync hydrates and projects a remotely signed Snippet',
    () async {
      final own = DeviceIdentity.create(sodium);
      final remoteMember = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      const serverSpaceId = '11111111-1111-4111-8111-111111111111';
      const vaultId = '22222222-2222-4222-8222-222222222222';
      const recordId = '55555555-5555-4555-8555-555555555555';
      const title = 'remote-snippet-second-device';
      final crypto = VaultCrypto(sodium);
      final envelope = await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: recordId,
        baseRevisionId: null,
        deviceId: remoteMember.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': recordId,
          'type': 'snippet',
          'title': title,
          'body': 'printf ready',
          'shell_kind': 'bash',
          'tags': <String>[],
        },
        identity: remoteMember,
      );
      final api = _DirectoryApiClient(
        own: own,
        remoteMember: remoteMember,
        envelope: envelope,
        includeRemoteMember: true,
      );
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: crypto,
        identity: own,
        serverSpaceId: serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: Uint8List.fromList(key),
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
            )
            ..identity = own
            ..activeVault = const VaultDescriptor(
              id: vaultId,
              role: 'viewer',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: false,
            )
            ..stage = ClientStage.workspace;

      try {
        await app.synchronize();

        final decrypted = await repository.loadRecords();
        expect(decrypted, hasLength(1));
        expect(decrypted.single['type'], 'snippet');
        expect(decrypted.single['title'], title);
        expect(decrypted.single['_record_id'], recordId);
        expect(app.snippets, hasLength(1));
        expect(app.snippets.single.title, title);
        expect(app.unavailableRecordCount, 0);
        expect(app.syncStatus, 'idle');
      } finally {
        app.dispose();
        await database.close();
        api.close();
        own.dispose();
        remoteMember.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'unknown decrypted record type stays encrypted and is reported unavailable',
    () async {
      final own = DeviceIdentity.create(sodium);
      final remoteMember = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      const serverSpaceId = '11111111-1111-4111-8111-111111111111';
      const vaultId = '22222222-2222-4222-8222-222222222222';
      const recordId = '66666666-6666-4666-8666-666666666666';
      const secretMarker = 'future-record-private-marker';
      final crypto = VaultCrypto(sodium);
      final envelope = await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: recordId,
        baseRevisionId: null,
        deviceId: remoteMember.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': recordId,
          'type': 'futureRecordKind',
          'payload': secretMarker,
        },
        identity: remoteMember,
      );
      final api = _DirectoryApiClient(
        own: own,
        remoteMember: remoteMember,
        envelope: envelope,
        includeRemoteMember: true,
      );
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: crypto,
        identity: own,
        serverSpaceId: serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: Uint8List.fromList(key),
      );
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              repositoryForTesting: repository,
            )
            ..identity = own
            ..activeVault = const VaultDescriptor(
              id: vaultId,
              role: 'viewer',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: false,
            )
            ..stage = ClientStage.workspace;

      try {
        await app.synchronize();
        expect(app.syncStatus, 'idle');
        expect(app.hosts, isEmpty);
        expect(app.credentials, isEmpty);
        expect(app.unavailableRecordCount, 1);
        expect(repository.unavailableRecordIds, [recordId]);
        expect(await repository.loadRecords(), isEmpty);
        final stored = await database.encryptedRecord(vaultId, recordId);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains(secretMarker)));
      } finally {
        app.dispose();
        await database.close();
        api.close();
        own.dispose();
        remoteMember.dispose();
        key.fillRange(0, key.length, 0);
      }
    },
  );

  test(
    'unknown event signer retains ciphertext and does not advance cursor',
    () async {
      final own = DeviceIdentity.create(sodium);
      final remoteMember = DeviceIdentity.create(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final key = sodium.randombytes.buf(32);
      final crypto = VaultCrypto(sodium);
      const serverSpaceId = '11111111-1111-4111-8111-111111111111';
      const vaultId = '22222222-2222-4222-8222-222222222222';
      final envelope = await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: serverSpaceId,
        vaultId: vaultId,
        recordId: '44444444-4444-4444-8444-444444444444',
        baseRevisionId: null,
        deviceId: remoteMember.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': '44444444-4444-4444-8444-444444444444',
          'type': 'host',
          'name': 'Unverified host',
        },
        identity: remoteMember,
      );
      final api = _DirectoryApiClient(
        own: own,
        remoteMember: remoteMember,
        envelope: envelope,
        includeRemoteMember: false,
      );
      final repository = SyncRepository(
        api: api,
        database: database,
        crypto: crypto,
        identity: own,
        serverSpaceId: serverSpaceId,
        instanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        vaultId: vaultId,
        keyEpoch: '1',
        membershipVersion: '1',
        serverGeneration: _serverGeneration,
        vaultKey: Uint8List.fromList(key),
      );

      await expectLater(
        repository.synchronize(),
        throwsA(
          isA<SyncControlPlaneRefreshRequiredException>().having(
            (error) => error.reason,
            'reason',
            SyncControlPlaneRefreshReason.missingEventSigner,
          ),
        ),
      );
      expect(
        await database.cachedEnvelopes(
          vaultId,
          instanceId: _instanceId,
          serverSpaceId: serverSpaceId,
        ),
        isEmpty,
      );
      final checkpoint = await database.checkpoint(
        vaultId,
        instanceId: _instanceId,
        serverSpaceId: serverSpaceId,
      );
      expect(checkpoint?.cursor, isNull);
      expect(checkpoint?.serverGeneration, isNull);
      expect(checkpoint?.syncStatus, 'epoch_update_required');

      await database.close();
      api.close();
      own.dispose();
      remoteMember.dispose();
      key.fillRange(0, key.length, 0);
    },
  );
}

class _DirectoryApiClient extends ApiClient {
  _DirectoryApiClient({
    required this.own,
    required this.remoteMember,
    required this.envelope,
    required this.includeRemoteMember,
  }) : super(baseUrl: 'https://vault-sync-test.example');

  final DeviceIdentity own;
  final DeviceIdentity remoteMember;
  final Map<String, Object?> envelope;
  final bool includeRemoteMember;
  var _eventsReturned = false;

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': own.deviceId,
      'signing_public_key': own.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    {
      'device_id': own.deviceId,
      'user_id': '55555555-5555-4555-8555-555555555555',
      'signing_public_key': own.signingPublicKey,
      'status': 'active',
    },
    if (includeRemoteMember)
      {
        'device_id': remoteMember.deviceId,
        'user_id': '66666666-6666-4666-8666-666666666666',
        'signing_public_key': remoteMember.signingPublicKey,
        'status': 'active',
      },
  ];

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async => ConflictChangesPage(
    vaultId: vaultId,
    afterSeq: afterSeq ?? '0',
    highWatermark: afterSeq ?? '0',
    events: const [],
    nextAfterSeq: afterSeq ?? '0',
    hasMore: false,
    serverGeneration: serverGeneration ?? _serverGeneration,
  );

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    if (_eventsReturned) {
      return const SyncPage(
        events: [],
        nextCursor: 'cursor-1',
        hasMore: false,
        serverGeneration: _serverGeneration,
      );
    }
    _eventsReturned = true;
    return SyncPage(
      events: [
        {
          'commit_seq': '1',
          'event_type': 'create',
          'record_id': (envelope['header']! as Map)['record_id'],
          'revision_id': (envelope['header']! as Map)['revision_id'],
          'envelope': envelope,
        },
      ],
      nextCursor: 'cursor-1',
      hasMore: false,
      serverGeneration: _serverGeneration,
    );
  }
}

class _GatedDecryptVaultCrypto extends VaultCrypto {
  _GatedDecryptVaultCrypto(super.sodium);

  final firstDecryptStarted = Completer<void>();
  final allowFirstDecrypt = Completer<void>();
  var _pausedFirstDecrypt = false;

  @override
  Future<Map<String, dynamic>> decryptRecord({
    required Uint8List vaultKey,
    required Map<String, dynamic> envelope,
    required Uint8List authorPublicKey,
  }) async {
    if (!_pausedFirstDecrypt) {
      _pausedFirstDecrypt = true;
      firstDecryptStarted.complete();
      await allowFirstDecrypt.future;
    }
    return super.decryptRecord(
      vaultKey: vaultKey,
      envelope: envelope,
      authorPublicKey: authorPublicKey,
    );
  }
}
