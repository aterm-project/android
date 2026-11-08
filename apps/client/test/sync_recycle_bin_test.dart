import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _instanceId = '44444444-4444-4444-8444-444444444444';
const _snapshotId = '55555555-5555-4555-8555-555555555555';
const _generation = '66666666-6666-4666-8666-666666666666';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'recycle bin verifies snapshot history and stages a signed restore',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final tombstone = await fixture.record(
          operation: 'delete',
          baseRevisionId: fixture.previousRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        final tombstoneHeader = Map<String, dynamic>.from(
          tombstone['header'] as Map,
        );
        fixture.api.setTombstone(
          tombstone,
          revisionEntry: VaultRevisionEntry(
            recordId: _recordId,
            revisionId: tombstoneHeader['revision_id'] as String,
            baseRevisionId: fixture.previousRevisionId,
            commitSeq: '2',
            operation: 'delete',
            deleted: true,
            createdAt: '2026-10-01T12:00:00Z',
            envelope: Map<String, dynamic>.from(tombstone),
            // Deliberately differs from created_at + the instance's 30 days.
            restoreUntil: DateTime.utc(2026, 11, 5, 9),
          ),
        );
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: tombstoneHeader['revision_id'] as String,
          envelope: Map<String, dynamic>.from(tombstone),
          commitSeq: '2',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );

        final entries = await fixture.repository.loadRecycleBin();
        expect(entries, hasLength(1));
        expect(entries.single.displayName, 'Production edge');
        expect(entries.single.recordType, 'host');
        expect(entries.single.canRestore, isTrue);
        expect(entries.single.restoreUntil, DateTime.utc(2026, 11, 5, 9));

        final restoredRevision = await fixture.repository
            .restoreRecycleBinRecord(
              recordId: entries.single.recordId,
              expectedTombstoneRevisionId: entries.single.tombstoneRevisionId,
              expectedPreviousRevisionId: entries.single.previousRevisionId!,
            );
        final pending = await fixture.database.allPendingOperations(_vaultId);
        expect(pending, hasLength(1));
        final envelope =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        final header = Map<String, dynamic>.from(envelope['header'] as Map);
        expect(header['operation'], 'restore');
        expect(header['revision_id'], restoredRevision);
        expect(header['base_revision_id'], tombstoneHeader['revision_id']);
        final decrypted = await fixture.crypto.decryptRecord(
          vaultKey: fixture.vaultKey,
          envelope: envelope,
          authorPublicKey: fixture.identity.signing.publicKey,
        );
        expect(decrypted['name'], 'Production edge');
        expect(decrypted['deleted'], isNull);
        expect(
          (await fixture.database.encryptedRecord(
            _vaultId,
            _recordId,
          ))?.isDeleted,
          isFalse,
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'restore fails closed when the server snapshot no longer has the tombstone',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final tombstone = await fixture.record(
          operation: 'delete',
          baseRevisionId: fixture.previousRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        final header = Map<String, dynamic>.from(tombstone['header'] as Map);
        fixture.api.snapshotItems = const [];
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: header['revision_id'] as String,
          envelope: Map<String, dynamic>.from(tombstone),
          commitSeq: '2',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );

        await expectLater(
          fixture.repository.restoreRecycleBinRecord(
            recordId: _recordId,
            expectedTombstoneRevisionId: header['revision_id'] as String,
            expectedPreviousRevisionId: fixture.previousRevisionId,
          ),
          throwsA(isA<LocalRecordHeadChangedException>()),
        );
        expect(await fixture.database.allPendingOperations(_vaultId), isEmpty);
        expect(
          (await fixture.database.encryptedRecord(
            _vaultId,
            _recordId,
          ))?.isDeleted,
          isTrue,
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'authoritative expired restore rejection removes only its exact outbox head',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final tombstone = await fixture.record(
          operation: 'delete',
          baseRevisionId: fixture.previousRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        final tombstoneHeader = Map<String, dynamic>.from(
          tombstone['header'] as Map,
        );
        fixture.api.setTombstone(
          tombstone,
          revisionEntry: VaultRevisionEntry(
            recordId: _recordId,
            revisionId: tombstoneHeader['revision_id'] as String,
            baseRevisionId: fixture.previousRevisionId,
            commitSeq: '2',
            operation: 'delete',
            deleted: true,
            createdAt: '2026-01-01T12:00:00Z',
            envelope: Map<String, dynamic>.from(tombstone),
          ),
        );
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: tombstoneHeader['revision_id'] as String,
          envelope: Map<String, dynamic>.from(tombstone),
          commitSeq: '2',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        final entries = await fixture.repository.loadRecycleBin();
        await fixture.repository.restoreRecycleBinRecord(
          recordId: _recordId,
          expectedTombstoneRevisionId: entries.single.tombstoneRevisionId,
          expectedPreviousRevisionId: entries.single.previousRevisionId!,
        );
        fixture.api.expireRestorePush = true;

        await expectLater(
          fixture.repository.synchronize(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'RECORD_RESTORE_EXPIRED',
            ),
          ),
        );
        expect(await fixture.database.allPendingOperations(_vaultId), isEmpty);
        final restoredCache = await fixture.database.encryptedRecord(
          _vaultId,
          _recordId,
        );
        expect(restoredCache?.revisionId, tombstoneHeader['revision_id']);
        expect(restoredCache?.commitSeq, '2');
        expect(restoredCache?.isDeleted, isTrue);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'purge verifies proof before atomically erasing the scoped cache',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final tombstone = await fixture.record(
          operation: 'delete',
          baseRevisionId: fixture.previousRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        final tombstoneHeader = Map<String, dynamic>.from(
          tombstone['header'] as Map,
        );
        fixture.api.setTombstone(
          tombstone,
          revisionEntry: VaultRevisionEntry(
            recordId: _recordId,
            revisionId: tombstoneHeader['revision_id'] as String,
            baseRevisionId: fixture.previousRevisionId,
            commitSeq: '2',
            operation: 'delete',
            deleted: true,
            createdAt: '2025-01-01T12:00:00Z',
            envelope: Map<String, dynamic>.from(tombstone),
            restoreUntil: DateTime.utc(2025, 2, 15, 7),
          ),
        );
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: tombstoneHeader['revision_id'] as String,
          envelope: Map<String, dynamic>.from(tombstone),
          commitSeq: '2',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );

        final entry = (await fixture.repository.loadRecycleBin()).single;
        final proof = await fixture.repository.purgeRecycleBinRecord(entry);

        expect(proof.recordId, _recordId);
        expect(proof.deletedRevisionId, entry.tombstoneRevisionId);
        expect(proof.deletedSeq, entry.deletedSeq);
        expect(
          await fixture.database.encryptedRecord(_vaultId, _recordId),
          isNull,
        );
        expect(
          await fixture.database.redactionProofForRecord(
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            vaultId: _vaultId,
            recordId: _recordId,
          ),
          isNotNull,
        );
        expect(fixture.api.purgeRequests, 1);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'automatic purge consent uses the exact tombstone and policy revisions',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final tombstone = await fixture.record(
          operation: 'delete',
          baseRevisionId: fixture.previousRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        final header = Map<String, dynamic>.from(tombstone['header'] as Map);
        fixture.api.setTombstone(
          tombstone,
          revisionEntry: VaultRevisionEntry(
            recordId: _recordId,
            revisionId: header['revision_id'] as String,
            baseRevisionId: fixture.previousRevisionId,
            commitSeq: '2',
            operation: 'delete',
            deleted: true,
            createdAt: '2026-10-01T12:00:00Z',
            envelope: Map<String, dynamic>.from(tombstone),
            autoPurgeEnabled: false,
            autoPurgeRevision: '0',
          ),
        );
        await fixture.database.storeRemoteEnvelope(
          vaultId: _vaultId,
          recordId: _recordId,
          revisionId: header['revision_id'] as String,
          envelope: Map<String, dynamic>.from(tombstone),
          commitSeq: '2',
          deleted: true,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );

        final entry = (await fixture.repository.loadRecycleBin()).single;
        expect(entry.autoPurgeEnabled, isFalse);
        expect(entry.autoPurgeRevision, '0');

        await fixture.repository.setRecycleBinRecordAutomaticPurge(
          entry,
          enabled: false,
        );
        expect(fixture.api.automaticPurgeRequests.single, {
          'vault_id': _vaultId,
          'record_id': _recordId,
          'expected_deleted_revision_id': entry.tombstoneRevisionId,
          'expected_deleted_seq': '2',
          'expected_policy_revision': '0',
          'enabled': false,
        });

        fixture.api.automaticPurgeResponseOverride = {
          'vault_id': _vaultId,
          'record_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'deleted_revision_id': entry.tombstoneRevisionId,
          'deleted_seq': entry.deletedSeq,
          'enabled': true,
          'policy_revision': '1',
        };
        await expectLater(
          fixture.repository.setRecycleBinRecordAutomaticPurge(
            entry,
            enabled: true,
          ),
          throwsFormatException,
        );

        fixture.api.automaticPurgeResponseOverride = {
          'vault_id': _vaultId,
          'record_id': entry.recordId,
          'deleted_revision_id': entry.tombstoneRevisionId,
          'deleted_seq': entry.deletedSeq,
          'enabled': true,
          'policy_revision': '00',
        };
        await expectLater(
          fixture.repository.setRecycleBinRecordAutomaticPurge(
            entry,
            enabled: true,
          ),
          throwsFormatException,
        );

        fixture.api.automaticPurgeResponseOverride = null;
        await fixture.repository.setRecycleBinRecordAutomaticPurge(
          entry,
          enabled: true,
        );
        expect(fixture.api.automaticPurgeRequests, hasLength(4));
        expect(fixture.api.automaticPurgeRequests.last, {
          'vault_id': _vaultId,
          'record_id': _recordId,
          'expected_deleted_revision_id': entry.tombstoneRevisionId,
          'expected_deleted_seq': '2',
          'expected_policy_revision': '0',
          'enabled': true,
        });

        fixture.api.setTombstone(
          tombstone,
          revisionEntry: VaultRevisionEntry(
            recordId: _recordId,
            revisionId: header['revision_id'] as String,
            baseRevisionId: fixture.previousRevisionId,
            commitSeq: '2',
            operation: 'delete',
            deleted: true,
            createdAt: '2026-10-01T12:00:00Z',
            envelope: Map<String, dynamic>.from(tombstone),
            autoPurgeEnabled: true,
            autoPurgeRevision: '1',
          ),
        );
        await expectLater(
          fixture.repository.setRecycleBinRecordAutomaticPurge(
            entry,
            enabled: false,
          ),
          throwsA(isA<LocalRecordHeadChangedException>()),
        );
        expect(fixture.api.automaticPurgeRequests, hasLength(4));
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('legacy history without restore_until cannot enable purge', () async {
    final fixture = await _Fixture.create(sodium);
    try {
      final tombstone = await fixture.record(
        operation: 'delete',
        baseRevisionId: fixture.previousRevisionId,
        plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
      );
      final tombstoneHeader = Map<String, dynamic>.from(
        tombstone['header'] as Map,
      );
      fixture.api.setTombstone(
        tombstone,
        revisionEntry: VaultRevisionEntry(
          recordId: _recordId,
          revisionId: tombstoneHeader['revision_id'] as String,
          baseRevisionId: fixture.previousRevisionId,
          commitSeq: '2',
          operation: 'delete',
          deleted: true,
          createdAt: '2025-01-01T12:00:00Z',
          envelope: Map<String, dynamic>.from(tombstone),
        ),
      );
      await fixture.database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: tombstoneHeader['revision_id'] as String,
        envelope: Map<String, dynamic>.from(tombstone),
        commitSeq: '2',
        deleted: true,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );

      final entry = (await fixture.repository.loadRecycleBin()).single;
      expect(entry.restoreUntil, isNull);
      await expectLater(
        fixture.repository.purgeRecycleBinRecord(entry),
        throwsA(isA<StateError>()),
      );
      expect(fixture.api.purgeRequests, 0);
    } finally {
      await fixture.dispose();
    }
  });
}

class _Fixture {
  _Fixture({
    required this.sodium,
    required this.identity,
    required this.database,
    required this.vaultKey,
    required this.crypto,
    required this.api,
    required this.repository,
    required this.previousRevisionId,
  });

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final ClientDatabase database;
  final Uint8List vaultKey;
  final VaultCrypto crypto;
  final _RecycleBinApi api;
  final SyncRepository repository;
  final String previousRevisionId;

  static Future<_Fixture> create(SodiumSumo sodium) async {
    final identity = DeviceIdentity.create(sodium);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final vaultKey = sodium.randombytes.buf(32);
    final crypto = VaultCrypto(sodium);
    final api = _RecycleBinApi(identity: identity, sodium: sodium);
    final previous = await crypto.encryptRecord(
      vaultKey: vaultKey,
      serverSpaceId: _serverSpaceId,
      vaultId: _vaultId,
      recordId: _recordId,
      baseRevisionId: null,
      deviceId: identity.deviceId,
      deviceSequence: '1',
      keyEpoch: '1',
      membershipVersion: '1',
      operation: 'create',
      plaintext: const {
        'id': _recordId,
        'type': 'host',
        'name': 'Production edge',
      },
      identity: identity,
    );
    api.revisionsById[(previous['header'] as Map)['revision_id'] as String] =
        previous;
    final repo = SyncRepository(
      api: api,
      database: database,
      crypto: crypto,
      identity: identity,
      serverSpaceId: _serverSpaceId,
      instanceId: _instanceId,
      accountId: '77777777-7777-4777-8777-777777777777',
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: _generation,
      vaultKey: vaultKey,
      trustedInstanceSigningPublicKey: identity.signingPublicKey,
    );
    return _Fixture(
      sodium: sodium,
      identity: identity,
      database: database,
      vaultKey: vaultKey,
      crypto: crypto,
      api: api,
      repository: repo,
      previousRevisionId: (previous['header'] as Map)['revision_id'] as String,
    );
  }

  Future<Map<String, Object?>> record({
    required String operation,
    required String? baseRevisionId,
    required Map<String, Object?> plaintext,
  }) => crypto.encryptRecord(
    vaultKey: vaultKey,
    serverSpaceId: _serverSpaceId,
    vaultId: _vaultId,
    recordId: _recordId,
    baseRevisionId: baseRevisionId,
    deviceId: identity.deviceId,
    deviceSequence: '2',
    keyEpoch: '1',
    membershipVersion: '1',
    operation: operation,
    plaintext: plaintext,
    identity: identity,
  );

  Future<void> dispose() async {
    await database.close();
    api.close();
    identity.dispose();
    vaultKey.fillRange(0, vaultKey.length, 0);
  }
}

class _RecycleBinApi extends ApiClient {
  _RecycleBinApi({required this.identity, required this.sodium})
    : super(baseUrl: 'https://recycle-bin.example.test');

  final DeviceIdentity identity;
  final SodiumSumo sodium;
  final Map<String, Map<String, dynamic>> revisionsById = {};
  List<Map<String, dynamic>> snapshotItems = const [];
  List<VaultRevisionEntry> revisionEntries = const [];
  bool expireRestorePush = false;
  int commitSeq = 2;
  int purgeRequests = 0;
  final List<Map<String, Object?>> automaticPurgeRequests = [];
  Map<String, dynamic>? automaticPurgeResponseOverride;

  void setTombstone(
    Map<String, Object?> envelope, {
    required VaultRevisionEntry revisionEntry,
  }) {
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    revisionsById[revisionId] = Map<String, dynamic>.from(envelope);
    revisionEntries = [revisionEntry];
    snapshotItems = [
      {
        'record_id': _recordId,
        'revision_id': revisionId,
        'commit_seq': '2',
        'deleted': true,
        'envelope': envelope,
      },
    ];
  }

  @override
  Future<InstanceInfo> fetchInstance() async => const InstanceInfo(
    instanceId: _instanceId,
    serverSpaceId: _serverSpaceId,
    generation: _generation,
    protocolVersion: 1,
    setupRequired: false,
    capabilities: ['snapshots'],
    restoreRetentionDays: 30,
  );

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': identity.deviceId,
      'signing_public_key': identity.signingPublicKey,
      'status': 'active',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      devices();

  @override
  Future<Map<String, dynamic>> createSnapshot(String vaultId) async => {
    'snapshot_id': _snapshotId,
    'high_watermark': '2',
    'conflict_high_watermark': '0',
    'next_cursor': 'checkpoint-cursor',
    'expires_at': '2030-01-01T00:00:00Z',
    'item_count': snapshotItems.length,
  };

  @override
  Future<Map<String, dynamic>> snapshot(
    String snapshotId, {
    int? limit,
    String? pageCursor,
  }) async => {
    'snapshot_id': _snapshotId,
    'high_watermark': '2',
    'conflict_high_watermark': '0',
    'next_cursor': 'checkpoint-cursor',
    'expires_at': '2030-01-01T00:00:00Z',
    'item_count': snapshotItems.length,
    'manifest': snapshotItems,
    'has_more': false,
    'next_page_cursor': null,
    'server_generation': _generation,
  };

  @override
  Future<VaultHistoryPage<VaultRevisionEntry>> revisions(
    String vaultId, {
    required String snapshotId,
    String? cursor,
    int limit = 500,
  }) async => VaultHistoryPage(
    snapshotId: _snapshotId,
    vaultId: _vaultId,
    highWatermark: '2',
    conflictHighWatermark: '0',
    entries: revisionEntries,
    nextCursor: null,
    hasMore: false,
    serverGeneration: _generation,
  );

  @override
  Future<Map<String, dynamic>> revision(
    String vaultId,
    String revisionId,
  ) async {
    final envelope = revisionsById[revisionId];
    if (envelope == null) {
      throw const ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'Revision not found.',
      );
    }
    return {'record_id': _recordId, 'envelope': envelope, 'commit_seq': '1'};
  }

  @override
  Future<Map<String, dynamic>> purgeRecord({
    required String vaultId,
    required String recordId,
    required String expectedDeletedRevisionId,
    required String expectedDeletedSeq,
  }) async {
    purgeRequests++;
    final payload = <String, Object?>{
      'format': 'atermius-record-redaction-proof-v1',
      'redaction_id': '77777777-7777-4777-8777-777777777777',
      'instance_id': _instanceId,
      'server_space_id': _serverSpaceId,
      'vault_id': vaultId,
      'record_id': recordId,
      'deleted_revision_id': expectedDeletedRevisionId,
      'deleted_seq': expectedDeletedSeq,
      'redaction_seq': '3',
      'signing_public_key': identity.signingPublicKey,
    };
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(payload))),
      secretKey: identity.signing.secretKey,
    );
    return {
      'status': 'purged',
      'already_purged': false,
      'redaction': {...payload, 'signature': encodeBase64Url(signature)},
    };
  }

  @override
  Future<Map<String, dynamic>> setRecordAutomaticPurge({
    required String vaultId,
    required String recordId,
    required String expectedDeletedRevisionId,
    required String expectedDeletedSeq,
    required String expectedPolicyRevision,
    required bool enabled,
  }) async {
    automaticPurgeRequests.add({
      'vault_id': vaultId,
      'record_id': recordId,
      'expected_deleted_revision_id': expectedDeletedRevisionId,
      'expected_deleted_seq': expectedDeletedSeq,
      'expected_policy_revision': expectedPolicyRevision,
      'enabled': enabled,
    });
    final currentTombstone = revisionEntries
        .where(
          (entry) =>
              entry.recordId == recordId &&
              entry.revisionId == expectedDeletedRevisionId,
        )
        .firstOrNull;
    final noOp = currentTombstone?.autoPurgeEnabled == enabled;
    return automaticPurgeResponseOverride ??
        {
          'vault_id': vaultId,
          'record_id': recordId,
          'deleted_revision_id': expectedDeletedRevisionId,
          'deleted_seq': expectedDeletedSeq,
          'enabled': enabled,
          'policy_revision': noOp
              ? expectedPolicyRevision
              : '${int.parse(expectedPolicyRevision) + 1}',
        };
  }

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async => const SyncPage(
    events: [],
    nextCursor: 'ordinary-cursor',
    hasMore: false,
    serverGeneration: _generation,
  );

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async => ConflictChangesPage(
    vaultId: _vaultId,
    afterSeq: afterSeq ?? '0',
    highWatermark: afterSeq ?? '0',
    events: const [],
    nextAfterSeq: afterSeq ?? '0',
    hasMore: false,
    serverGeneration: _generation,
  );

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    if (expireRestorePush) {
      throw const ApiException(
        statusCode: 409,
        code: 'RECORD_RESTORE_EXPIRED',
        message: 'Restore retention expired.',
        details: {'restore_until': '2026-01-31T12:00:00Z'},
      );
    }
    final operations = (batch['operations'] as List<dynamic>)
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .toList(growable: false);
    return {
      'batch_id': batch['batch_id'],
      'results': [
        for (final operation in operations)
          {
            'op_id': (operation['header'] as Map)['op_id'],
            'revision_id': (operation['header'] as Map)['revision_id'],
            'commit_seq': '${++commitSeq}',
            'already_committed': false,
          },
      ],
    };
  }
}
