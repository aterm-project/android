import 'dart:typed_data';
import 'dart:convert';

import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _recordId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _otherRecordId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _blobId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _objectId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _serverSpaceId = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'attachment transfer progress projects metadata without BLOB rows',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const uploadJobId = 'upload:$_vaultId:$_recordId:$_blobId';
      try {
        await database.beginBlobJob(
          jobId: uploadJobId,
          vaultId: _vaultId,
          recordId: _recordId,
          blobId: _blobId,
          direction: 'upload',
          state: 'uploading',
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        const firstObject = '11111111-1111-4111-8111-111111111111';
        const secondObject = '22222222-2222-4222-8222-222222222222';
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: firstObject,
          sha256: List.filled(64, 'a').join(),
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: secondObject,
          sha256: List.filled(64, 'b').join(),
          bytes: Uint8List.fromList([4, 5]),
        );
        await database.updateBlobUploadProgress(
          jobId: uploadJobId,
          objectId: firstObject,
          uploadId: '33333333-3333-4333-8333-333333333333',
          chunkSize: 1024 * 1024,
          nextChunkIndex: 1,
        );

        final progress = await database.blobJobObjectProgressRows(uploadJobId);
        expect(progress, hasLength(2));
        expect(progress.map((item) => item.objectId), [
          firstObject,
          secondObject,
        ]);
        expect(progress.first.stagedBytes, 3);
        expect(progress.first.size, 3);
        expect(progress.first.nextChunkIndex, 1);
        expect(progress.first.uploadChunkSize, 1024 * 1024);
        expect(progress.first.transferred, isFalse);
        expect(progress.last.stagedBytes, 2);
        // This projection type has no ciphertext field; callers must request a
        // single BlobJobObject explicitly before processing one object.
        expect(
          await database.blobJobObject(uploadJobId, secondObject),
          isNotNull,
        );
      } finally {
        await database.close();
      }
    },
  );

  test('an incomplete upload gates only its Host record outbox row', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    try {
      await _queueRecord(
        database,
        _recordId,
        '11111111-1111-4111-8111-111111111111',
        objectRefs: [_objectId],
      );
      await _queueRecord(
        database,
        _otherRecordId,
        '22222222-2222-4222-8222-222222222222',
      );

      await database.beginBlobJob(
        jobId: 'upload:$_vaultId:$_recordId:$_blobId',
        vaultId: _vaultId,
        recordId: _recordId,
        blobId: _blobId,
        direction: 'upload',
        state: 'uploading',
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
      );
      await database.stageBlobUploadObject(
        jobId: 'upload:$_vaultId:$_recordId:$_blobId',
        objectId: _objectId,
        sha256: List.filled(64, 'a').join(),
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await database.pendingRecordReferencesObject(
          vaultId: _vaultId,
          recordId: _recordId,
          objectId: _objectId,
        ),
        isTrue,
      );

      expect(await database.queuedOperations(_vaultId), hasLength(2));
      expect(
        (await database.pushableOperations(
          _vaultId,
        )).map((row) => row.recordId).toSet(),
        {_otherRecordId},
      );

      await database.deleteBlobJob('upload:$_vaultId:$_recordId:$_blobId');
      expect(
        (await database.pushableOperations(
          _vaultId,
        )).map((row) => row.recordId).toSet(),
        {_recordId, _otherRecordId},
      );
    } finally {
      await database.close();
    }
  });

  test(
    'Host tombstone atomically compacts queued attachment refs and transfer jobs',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const uploadJobId = 'upload:$_vaultId:$_recordId:$_blobId';
      const downloadJobId = 'download:$_vaultId:$_recordId:$_blobId';
      try {
        await _queueRecord(
          database,
          _recordId,
          '11111111-1111-4111-8111-111111111111',
          objectRefs: [_objectId],
        );
        await database.beginBlobJob(
          jobId: uploadJobId,
          vaultId: _vaultId,
          recordId: _recordId,
          blobId: _blobId,
          direction: 'upload',
          state: 'uploading',
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: _objectId,
          sha256: List.filled(64, 'a').join(),
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        await database.beginBlobJob(
          jobId: downloadJobId,
          vaultId: _vaultId,
          recordId: _recordId,
          blobId: _blobId,
          direction: 'download',
          state: 'queued',
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );

        await _queueTombstone(database, cleanupAttachmentJobs: true);

        final operations = await database.queuedOperations(_vaultId);
        expect(operations, hasLength(1));
        final tombstone = operations.single;
        final envelope = jsonDecode(tombstone.envelopeJson) as Map;
        final header = envelope['header'] as Map;
        expect(header['operation'], 'delete');
        expect(header['record_id'], _recordId);
        expect(header.containsKey('object_refs'), isFalse);
        expect(await database.blobJobsForRecord(_vaultId, _recordId), isEmpty);
        expect(
          (await database.pushableOperations(_vaultId)).map((row) => row.opId),
          [header['op_id']],
          reason: 'The durable deletion tombstone must remain pushable.',
        );
        expect(
          await database.pendingRecordReferencesObject(
            vaultId: _vaultId,
            recordId: _recordId,
            objectId: _objectId,
          ),
          isFalse,
        );
      } finally {
        await database.close();
      }
    },
  );

  test(
    'Host tombstone retains upload gate for an immutable sent reference',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const uploadJobId = 'upload:$_vaultId:$_recordId:$_blobId';
      const referenceOpId = '11111111-1111-4111-8111-111111111111';
      try {
        await _queueRecord(
          database,
          _recordId,
          referenceOpId,
          objectRefs: [_objectId],
        );
        await database.markAttempted([referenceOpId]);
        await database.beginBlobJob(
          jobId: uploadJobId,
          vaultId: _vaultId,
          recordId: _recordId,
          blobId: _blobId,
          direction: 'upload',
          state: 'uploading',
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: _objectId,
          sha256: List.filled(64, 'a').join(),
          bytes: Uint8List.fromList([1, 2, 3]),
        );

        await _queueTombstone(database, cleanupAttachmentJobs: true);

        final operations = await database.queuedOperations(_vaultId);
        expect(operations, hasLength(2));
        expect(operations.first.status, 'sent');
        expect(operations.last.status, 'queued');
        expect(
          await database.blobJobsForRecord(_vaultId, _recordId),
          hasLength(1),
        );
        expect(await database.blobJobObjectRows(uploadJobId), hasLength(1));
        expect(
          await database.pushableOperations(_vaultId),
          isEmpty,
          reason:
              'An immutable pending reference keeps the upload and per-record gate.',
        );
      } finally {
        await database.close();
      }
    },
  );

  test(
    'failed tombstone cleanup rolls back tombstone and keeps transfer bytes',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const uploadJobId = 'upload:$_vaultId:$_recordId:$_blobId';
      const referenceOpId = '11111111-1111-4111-8111-111111111111';
      try {
        await database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          baseRevisionId: null,
          envelope: {
            'header': {
              'op_id': referenceOpId,
              'revision_id': referenceOpId,
              'object_refs': null,
            },
          },
          deleted: false,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        await database.markAttempted([referenceOpId]);
        await database.beginBlobJob(
          jobId: uploadJobId,
          vaultId: _vaultId,
          recordId: _recordId,
          blobId: _blobId,
          direction: 'upload',
          state: 'uploading',
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        await database.stageBlobUploadObject(
          jobId: uploadJobId,
          objectId: _objectId,
          sha256: List.filled(64, 'a').join(),
          bytes: Uint8List.fromList([1, 2, 3]),
        );

        await expectLater(
          _queueTombstone(database, cleanupAttachmentJobs: true),
          throwsA(isA<StateError>()),
        );

        expect(await database.queuedOperations(_vaultId), hasLength(1));
        expect(
          (await database.queuedOperations(_vaultId)).single.opId,
          referenceOpId,
        );
        expect(
          (await database.cachedEnvelopes(_vaultId)).single.isDeleted,
          isFalse,
        );
        expect(
          await database.blobJobsForRecord(_vaultId, _recordId),
          hasLength(1),
        );
        expect(await database.blobJobObjectRows(uploadJobId), hasLength(1));
      } finally {
        await database.close();
      }
    },
  );
}

Future<void> _queueTombstone(
  ClientDatabase database, {
  required bool cleanupAttachmentJobs,
}) => database.putLocalOperation(
  vaultId: _vaultId,
  recordId: _recordId,
  baseRevisionId: null,
  envelope: {
    'header': {
      'op_id': '99999999-9999-4999-8999-999999999999',
      'revision_id': '99999999-9999-4999-8999-999999999999',
      'record_id': _recordId,
      'operation': 'delete',
    },
  },
  deleted: true,
  instanceId: _instanceId,
  serverSpaceId: _serverSpaceId,
  cleanupAttachmentJobsOnDelete: cleanupAttachmentJobs,
);

Future<void> _queueRecord(
  ClientDatabase database,
  String recordId,
  String opId, {
  List<String> objectRefs = const [],
}) => database.putLocalOperation(
  vaultId: _vaultId,
  recordId: recordId,
  baseRevisionId: null,
  envelope: {
    'header': {
      'op_id': opId,
      'revision_id': opId,
      if (objectRefs.isNotEmpty) 'object_refs': objectRefs,
    },
  },
  deleted: false,
  instanceId: _instanceId,
  serverSpaceId: _serverSpaceId,
);
