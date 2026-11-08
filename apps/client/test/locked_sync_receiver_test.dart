import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/locked_sync_receiver.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _serverGeneration = '77777777-7777-4777-8777-777777777777';
const _instanceSigningKey = 'instance-public-key-pin';
const _plaintextMarker = 'locked-receiver-plaintext-marker';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('empty locked polls do not accumulate inbox pages', () async {
    final sodium = await SodiumSumoInit.init();
    final own = DeviceIdentity.create(sodium);
    final writer = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _LockedReceiverApi(own: own, writer: writer, event: null);
    final receiver = LockedSyncReceiver(
      api: api,
      database: database,
      crypto: VaultCrypto(sodium),
      instanceId: _instanceId,
      serverSpaceId: _serverSpaceId,
      vaultId: _vaultId,
      serverGeneration: _serverGeneration,
      trustedInstanceSigningPublicKey: _instanceSigningKey,
    );

    try {
      expect(await receiver.receive(), 0);
      expect(await receiver.receive(), 0);
      expect(
        await database.readLockedSyncInboxPages(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          serverGeneration: _serverGeneration,
        ),
        isEmpty,
      );
      final checkpoint =
          await (database.select(database.lockedSyncCheckpoints)..where(
                (row) =>
                    row.vaultId.equals(_vaultId) &
                    row.instanceId.equals(_instanceId) &
                    row.serverSpaceId.equals(_serverSpaceId),
              ))
              .getSingle();
      expect(checkpoint.nextPageIndex, 0);
      expect(checkpoint.cursor, isNull);
    } finally {
      api.close();
      own.dispose();
      writer.dispose();
      await database.close();
    }
  });

  test(
    'locked receiver stores signed ciphertext and cursor before keyed replay',
    () async {
      final sodium = await SodiumSumoInit.init();
      final own = DeviceIdentity.create(sodium);
      final writer = DeviceIdentity.create(sodium);
      final vaultKey = sodium.randombytes.buf(32);
      final crypto = _CountingVaultCrypto(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final envelope = await crypto.encryptRecord(
        vaultKey: vaultKey,
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        recordId: _recordId,
        baseRevisionId: null,
        deviceId: writer.deviceId,
        deviceSequence: '1',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: const {
          'id': _recordId,
          'type': 'host',
          'name': _plaintextMarker,
          'address': '192.0.2.41',
          'username': 'locked-test',
        },
        identity: writer,
      );
      final api = _LockedReceiverApi(
        own: own,
        writer: writer,
        event: {
          'commit_seq': '1',
          'event_type': 'create',
          'record_id': _recordId,
          'revision_id': (envelope['header']! as Map)['revision_id'],
          'envelope': envelope,
        },
      );
      final receiver = LockedSyncReceiver(
        api: api,
        database: database,
        crypto: crypto,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        vaultId: _vaultId,
        serverGeneration: _serverGeneration,
        trustedInstanceSigningPublicKey: _instanceSigningKey,
      );

      try {
        expect(await receiver.receive(), 1);
        expect(crypto.decryptCalls, 0);
        expect(api.pushCalls, 0);
        expect(
          await database.checkpoint(
            _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
          ),
          isNull,
        );
        final lockedCheckpoint =
            await (database.select(database.lockedSyncCheckpoints)..where(
                  (row) =>
                      row.vaultId.equals(_vaultId) &
                      row.instanceId.equals(_instanceId) &
                      row.serverSpaceId.equals(_serverSpaceId),
                ))
                .getSingle();
        expect(lockedCheckpoint.cursor, 'opaque-cursor-one');
        expect(lockedCheckpoint.nextPageIndex, 1);

        final pages = await database.readLockedSyncInboxPages(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          serverGeneration: _serverGeneration,
        );
        expect(pages, hasLength(1));
        expect(pages.single.eventsJson, contains('ciphertext'));
        expect(pages.single.eventsJson, isNot(contains(_plaintextMarker)));
        expect(
          await database.cachedEnvelopes(
            _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
          ),
          isEmpty,
        );
        expect(api.changesRequests.map((cursor) => cursor ?? '<initial>'), [
          '<initial>',
        ]);

        final repository = SyncRepository(
          api: api,
          database: database,
          crypto: crypto,
          identity: own,
          serverSpaceId: _serverSpaceId,
          instanceId: _instanceId,
          accountId: '55555555-5555-4555-8555-555555555555',
          vaultId: _vaultId,
          keyEpoch: '1',
          membershipVersion: '1',
          serverGeneration: _serverGeneration,
          vaultKey: Uint8List.fromList(vaultKey),
          trustedInstanceSigningPublicKey: _instanceSigningKey,
          canWrite: false,
        );
        final result = await repository.synchronize();
        expect(result.receivedCount, 1);
        expect(result.status, 'read_only');
        expect(crypto.decryptCalls, 1);
        expect(api.pushCalls, 0);
        expect(
          await database.readLockedSyncInboxPages(
            vaultId: _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            serverGeneration: _serverGeneration,
          ),
          isEmpty,
        );
        final checkpoint = await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(checkpoint?.cursor, 'opaque-cursor-two');
        final alignedLockedCheckpoint =
            await (database.select(database.lockedSyncCheckpoints)..where(
                  (row) =>
                      row.vaultId.equals(_vaultId) &
                      row.instanceId.equals(_instanceId) &
                      row.serverSpaceId.equals(_serverSpaceId),
                ))
                .getSingle();
        expect(alignedLockedCheckpoint.cursor, checkpoint?.cursor);
        expect(alignedLockedCheckpoint.nextPageIndex, 0);
        expect(api.changesRequests, [null, 'opaque-cursor-one']);
        final records = await repository.loadRecords();
        expect(records.single['name'], _plaintextMarker);
        expect(crypto.decryptCalls, 2);
        final storedEnvelope = (await database.cachedEnvelopes(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        )).single.envelopeJson;
        expect(storedEnvelope, contains('ciphertext'));
        expect(storedEnvelope, isNot(contains(_plaintextMarker)));
      } finally {
        api.close();
        own.dispose();
        writer.dispose();
        vaultKey.fillRange(0, vaultKey.length, 0);
        await database.close();
      }
    },
  );
}

class _CountingVaultCrypto extends VaultCrypto {
  _CountingVaultCrypto(super.sodium);

  var decryptCalls = 0;

  @override
  Future<Map<String, dynamic>> decryptRecord({
    required Uint8List vaultKey,
    required Map<String, dynamic> envelope,
    required Uint8List authorPublicKey,
  }) {
    decryptCalls++;
    return super.decryptRecord(
      vaultKey: vaultKey,
      envelope: envelope,
      authorPublicKey: authorPublicKey,
    );
  }
}

class _LockedReceiverApi extends ApiClient {
  _LockedReceiverApi({
    required this.own,
    required this.writer,
    required this.event,
  }) : super(baseUrl: 'https://locked-sync-test.example');

  final DeviceIdentity own;
  final DeviceIdentity writer;
  final Map<String, dynamic>? event;
  final List<String?> changesRequests = [];
  var pushCalls = 0;
  var cursorAdvanced = false;

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
      'signing_public_key': own.signingPublicKey,
      'status': 'active',
    },
    {
      'device_id': writer.deviceId,
      'signing_public_key': writer.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    changesRequests.add(cursor);
    if (cursor == null && event != null) {
      return SyncPage(
        events: [event!],
        nextCursor: 'opaque-cursor-one',
        hasMore: false,
        serverGeneration: _serverGeneration,
      );
    }
    final nextCursor = cursor == 'opaque-cursor-one' && !cursorAdvanced
        ? 'opaque-cursor-two'
        : cursor;
    if (nextCursor != cursor) cursorAdvanced = true;
    return SyncPage(
      events: const [],
      nextCursor: nextCursor,
      hasMore: false,
      serverGeneration: _serverGeneration,
    );
  }

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
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    pushCalls++;
    throw StateError('Locked sync acceptance must never push.');
  }
}
