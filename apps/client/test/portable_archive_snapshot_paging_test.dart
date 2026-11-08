import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/archive/archive_codec.dart';
import 'package:aterm_client/archive/portable_vault_archive.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = '22222222-2222-4222-8222-222222222222';
const _spaceId = '33333333-3333-4333-8333-333333333333';
const _snapshotId = '44444444-4444-4444-8444-444444444444';
const _generation = '55555555-5555-4555-8555-555555555555';
const _expiresAt = '2026-10-09T00:00:00Z';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'portable export follows every snapshot page before sealing archive',
    () async {
      final h = await _makeHarness(sodium);
      Uint8List? container;
      Uint8List? clearPayload;
      try {
        final requestedCursors = <String?>[];
        h.api.onSnapshotRequest = requestedCursors.add;
        container = await h.service.exportArchive(
          context: h.context,
          exportPassword: 'a sufficiently long archive password',
        );
        clearPayload = await VaultArchiveCodec(sodium).open(
          password: 'a sufficiently long archive password',
          container: container,
          expectedServerSpaceId: _spaceId,
          expectedVaultId: h.initial.vaultId,
        );
        final unpacked = VaultArchiveCodec.unpackPayload(clearPayload);
        expect((unpacked.manifest['snapshot_heads'] as List), hasLength(2));
        expect(requestedCursors, [null, 'opaque-page-2']);
      } finally {
        clearPayload?.fillRange(0, clearPayload.length, 0);
        container?.fillRange(0, container.length, 0);
        await h.dispose();
      }
    },
  );

  test(
    'portable export rejects page metadata drift before returning an archive',
    () async {
      final h = await _makeHarness(sodium);
      final second = Map<String, dynamic>.from(h.api.snapshotPages[1])
        ..['conflict_high_watermark'] = '1';
      h.api.snapshotPages[1] = second;
      try {
        await expectLater(
          h.service.exportArchive(
            context: h.context,
            exportPassword: 'a sufficiently long archive password',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(h.api.snapshotRequests, [null, 'opaque-page-2']);
        expect(await h.database.checkpoint(h.initial.vaultId), isNull);
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'portable export page failure returns no archive and leaves local state untouched',
    () async {
      final h = await _makeHarness(sodium);
      h.api.failSnapshotPage = 2;
      try {
        await expectLater(
          h.service.exportArchive(
            context: h.context,
            exportPassword: 'a sufficiently long archive password',
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'SERVICE_UNAVAILABLE',
            ),
          ),
        );
        expect(h.api.snapshotRequests, [null, 'opaque-page-2']);
        expect(await h.database.checkpoint(h.initial.vaultId), isNull);
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'portable export rejects an aggregate manifest over 64 MiB before history reads',
    () async {
      final h = await _makeHarness(sodium);
      h.api.createItemCount = 1;
      h.api.snapshotPages = [
        {
          'snapshot_id': _snapshotId,
          'high_watermark': '2',
          'conflict_high_watermark': '0',
          'next_cursor': 'archive-sync-cursor',
          'expires_at': _expiresAt,
          'item_count': 1,
          'manifest': [
            {'padding': _repeatX(64 * 1024 * 1024)},
          ],
          'has_more': false,
          'next_page_cursor': null,
        },
      ];
      try {
        await expectLater(
          h.service.exportArchive(
            context: h.context,
            exportPassword: 'a sufficiently long archive password',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('64 MiB'),
            ),
          ),
        );
        expect(h.api.revisionRequests, 0);
        expect(await h.database.checkpoint(h.initial.vaultId), isNull);
      } finally {
        await h.dispose();
      }
    },
  );
}

String _repeatX(int count) {
  var block = 'x';
  var remaining = count;
  final buffer = StringBuffer();
  while (remaining > 0) {
    if (remaining.isOdd) buffer.write(block);
    remaining >>= 1;
    if (remaining > 0) block += block;
  }
  return buffer.toString();
}

Future<_ArchiveHarness> _makeHarness(SodiumSumo sodium) async {
  final identity = DeviceIdentity.create(sodium);
  final crypto = VaultCrypto(sodium);
  final initial = await crypto.createInitialVault(
    accountId: _accountId,
    name: 'Paging fixture',
    identity: identity,
  );
  final signerRow = <String, dynamic>{
    'device_id': identity.deviceId,
    'user_id': _accountId,
    'name': 'Archive paging test device',
    'signing_public_key': identity.signingPublicKey,
    'encryption_public_key': identity.encryptionPublicKey,
    'status': 'active',
    'created_at': _expiresAt,
  };
  final membership = Map<String, dynamic>.from(
    initial.payload['membership'] as Map,
  );
  final body = Map<String, dynamic>.from(membership['manifest'] as Map);
  final signedContext = <String, Object?>{
    'vault_id': initial.vaultId,
    'membership_version': membership['membership_version'],
    'previous_digest': membership['previous_digest'],
    'manifest': body,
  };
  final digestBytes = await cryptography.Sha256().hash(
    utf8.encode(canonicalJson(signedContext)),
  );
  final digest = digestBytes.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final wrapper = <String, Object?>{
    ...signedContext,
    'signature': membership['signature'],
  };
  final membershipRow = <String, dynamic>{
    'membership_version': 1,
    'previous_digest': null,
    'manifest': wrapper,
    'digest': digest,
    'signer_device_id': identity.deviceId,
    'signature': membership['signature'],
    'created_at': _expiresAt,
  };
  final keyEnvelope = Map<String, dynamic>.from(
    initial.payload['key_envelope'] as Map,
  )..['signer_device_id'] = identity.deviceId;
  final recordEnvelopes = <Map<String, dynamic>>[];
  final revisions = <VaultRevisionEntry>[];
  for (final (index, recordId) in [
    '66666666-6666-4666-8666-666666666666',
    '77777777-7777-4777-8777-777777777777',
  ].indexed) {
    final sequence = '${index + 1}';
    final envelope = await crypto.encryptRecord(
      vaultKey: initial.vaultKey,
      serverSpaceId: _spaceId,
      vaultId: initial.vaultId,
      recordId: recordId,
      baseRevisionId: null,
      deviceId: identity.deviceId,
      deviceSequence: sequence,
      keyEpoch: '1',
      membershipVersion: '1',
      operation: 'create',
      plaintext: {'id': recordId, 'type': 'host', 'name': 'Record $sequence'},
      identity: identity,
    );
    final canonicalEnvelope = Map<String, dynamic>.from(envelope);
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    recordEnvelopes.add({
      'record_id': recordId,
      'revision_id': header['revision_id'],
      'commit_seq': sequence,
      'deleted': false,
      'envelope': canonicalEnvelope,
    });
    revisions.add(
      VaultRevisionEntry(
        recordId: recordId,
        revisionId: header['revision_id'] as String,
        baseRevisionId: null,
        commitSeq: sequence,
        operation: 'create',
        deleted: false,
        createdAt: _expiresAt,
        envelope: canonicalEnvelope,
      ),
    );
  }
  final api =
      _SnapshotArchiveApi(
          signerRow: signerRow,
          membershipRow: membershipRow,
          revisionEntries: revisions,
        )
        ..snapshotPages = [
          {
            'snapshot_id': _snapshotId,
            'high_watermark': '2',
            'conflict_high_watermark': '0',
            'next_cursor': 'archive-sync-cursor',
            'expires_at': _expiresAt,
            'item_count': 2,
            'manifest': [recordEnvelopes.first],
            'has_more': true,
            'next_page_cursor': 'opaque-page-2',
          },
          {
            'snapshot_id': _snapshotId,
            'high_watermark': '2',
            'conflict_high_watermark': '0',
            'next_cursor': 'archive-sync-cursor',
            'expires_at': _expiresAt,
            'item_count': 2,
            'manifest': [recordEnvelopes.last],
            'has_more': false,
            'next_page_cursor': null,
          },
        ];
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final context = VaultArchiveContext(
    instanceId: '88888888-8888-4888-8888-888888888888',
    serverSpaceId: _spaceId,
    accountId: _accountId,
    device: identity,
    vault: VaultDescriptor(
      id: initial.vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
      encryptedDisplayNameEnvelope: Map<String, dynamic>.from(
        initial.payload['name_envelope'] as Map,
      ),
      keyEnvelopes: [keyEnvelope],
    ),
    epochKeysByVersion: {'1:1': initial.vaultKey},
  );
  return _ArchiveHarness(
    sodium: sodium,
    identity: identity,
    initial: initial,
    database: database,
    api: api,
    context: context,
    service: PortableVaultArchiveService(
      sodium: sodium,
      api: api,
      database: database,
      crypto: crypto,
    ),
  );
}

class _ArchiveHarness {
  const _ArchiveHarness({
    required this.sodium,
    required this.identity,
    required this.initial,
    required this.database,
    required this.api,
    required this.context,
    required this.service,
  });

  final SodiumSumo sodium;
  final DeviceIdentity identity;
  final InitialVaultMaterial initial;
  final ClientDatabase database;
  final _SnapshotArchiveApi api;
  final VaultArchiveContext context;
  final PortableVaultArchiveService service;

  Future<void> dispose() async {
    api.close();
    identity.dispose();
    initial.vaultKey.fillRange(0, initial.vaultKey.length, 0);
    await database.close();
  }
}

class _SnapshotArchiveApi extends ApiClient {
  _SnapshotArchiveApi({
    required this.signerRow,
    required this.membershipRow,
    required this.revisionEntries,
  }) : super(baseUrl: 'https://archive-snapshot.test');

  final Map<String, dynamic> signerRow;
  final Map<String, dynamic> membershipRow;
  final List<VaultRevisionEntry> revisionEntries;
  List<Map<String, dynamic>> snapshotPages = const [];
  final List<String?> snapshotRequests = [];
  void Function(String?)? onSnapshotRequest;
  int? failSnapshotPage;
  int createItemCount = 2;
  int revisionRequests = 0;
  int _snapshotRequests = 0;

  @override
  Future<List<Map<String, dynamic>>> devices() async => const [];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    signerRow,
  ];

  @override
  Future<Map<String, dynamic>> membership(
    String vaultId, {
    int from = 0,
  }) async => {
    'manifests': [membershipRow],
  };

  @override
  Future<Map<String, dynamic>> createSnapshot(String vaultId) async => {
    'snapshot_id': _snapshotId,
    'high_watermark': '2',
    'conflict_high_watermark': '0',
    'next_cursor': 'archive-sync-cursor',
    'expires_at': _expiresAt,
    'item_count': createItemCount,
  };

  @override
  Future<Map<String, dynamic>> snapshot(
    String snapshotId, {
    int? limit,
    String? pageCursor,
  }) async {
    _snapshotRequests++;
    snapshotRequests.add(pageCursor);
    onSnapshotRequest?.call(pageCursor);
    if (failSnapshotPage == _snapshotRequests) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'Snapshot archive page failed',
      );
    }
    final index = _snapshotRequests - 1;
    if (index >= snapshotPages.length) {
      throw StateError('Unexpected archive snapshot page $index.');
    }
    return snapshotPages[index];
  }

  @override
  Future<VaultHistoryPage<VaultRevisionEntry>> revisions(
    String vaultId, {
    required String snapshotId,
    String? cursor,
    int limit = 500,
  }) async {
    revisionRequests++;
    return VaultHistoryPage(
      snapshotId: snapshotId,
      vaultId: vaultId,
      highWatermark: '2',
      conflictHighWatermark: '0',
      entries: revisionEntries,
      nextCursor: null,
      hasMore: false,
      serverGeneration: _generation,
    );
  }

  @override
  Future<VaultHistoryPage<VaultConflictEntry>> conflicts(
    String vaultId, {
    required String snapshotId,
    String? cursor,
    int limit = 500,
  }) async => VaultHistoryPage(
    snapshotId: snapshotId,
    vaultId: vaultId,
    highWatermark: '2',
    conflictHighWatermark: '0',
    entries: const [],
    nextCursor: null,
    hasMore: false,
    serverGeneration: _generation,
  );
}
