import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_migration_target_validator.dart';

void main() {
  const vaultId = '10000000-0000-4000-8000-000000000001';
  const stagedRecordId = '20000000-0000-4000-8000-000000000002';
  const extraRecordId = '30000000-0000-4000-8000-000000000003';
  const stagedOpId = '40000000-0000-4000-8000-000000000004';
  const extraOpId = '50000000-0000-4000-8000-000000000005';

  String envelopeJson(String recordId, String opId) =>
      '{"ciphertext":"opaque","header":{"op_id":"$opId","record_id":"$recordId"}}';

  LocalMigrationStagedItem staged() => LocalMigrationStagedItem(
    recordId: stagedRecordId,
    sourceRevisionId: '60000000-0000-4000-8000-000000000006',
    recordType: 'host',
    targetEnvelopeJson: envelopeJson(stagedRecordId, stagedOpId),
    targetEnvelopeSha256: List<String>.filled(64, 'a').join(),
  );

  EncryptedRecord cached({
    required String recordId,
    required String operation,
    bool deleted = false,
    String? commitSeq = '1',
  }) => EncryptedRecord(
    vaultId: vaultId,
    recordId: recordId,
    revisionId: '70000000-0000-4000-8000-000000000007',
    envelopeJson: envelopeJson(recordId, operation),
    isDeleted: deleted,
    commitSeq: commitSeq,
    updatedAt: 1,
  );

  PendingOperation pending({
    required String recordId,
    required String operation,
    required String json,
  }) => PendingOperation(
    opId: operation,
    vaultId: vaultId,
    recordId: recordId,
    envelopeJson: json,
    status: 'queued',
    attemptCount: 0,
    createdAt: 1,
  );

  test(
    'allows unrelated destination records while matching staged envelopes',
    () {
      validateLocalMigrationTargetState(
        cached: [
          cached(recordId: stagedRecordId, operation: stagedOpId),
          cached(recordId: extraRecordId, operation: extraOpId),
        ],
        pending: [
          pending(
            recordId: stagedRecordId,
            operation: stagedOpId,
            json: envelopeJson(stagedRecordId, stagedOpId),
          ),
          pending(
            recordId: extraRecordId,
            operation: extraOpId,
            json: envelopeJson(extraRecordId, extraOpId),
          ),
        ],
        stagedById: {stagedRecordId: staged()},
      );
    },
  );

  test(
    'requires every staged record to be committed but ignores other work',
    () {
      validateLocalMigrationTargetState(
        cached: [
          cached(recordId: stagedRecordId, operation: stagedOpId),
          cached(recordId: extraRecordId, operation: extraOpId),
        ],
        pending: [
          pending(
            recordId: extraRecordId,
            operation: extraOpId,
            json: envelopeJson(extraRecordId, extraOpId),
          ),
        ],
        stagedById: {stagedRecordId: staged()},
        requireAllCommitted: true,
      );
    },
  );

  test('rejects changed or deleted staged target records', () {
    for (final row in [
      cached(recordId: stagedRecordId, operation: extraOpId),
      cached(recordId: stagedRecordId, operation: stagedOpId, deleted: true),
    ]) {
      expect(
        () => validateLocalMigrationTargetState(
          cached: [row],
          pending: const [],
          stagedById: {stagedRecordId: staged()},
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects staged target records that are absent or uncommitted at finish',
    () {
      expect(
        () => validateLocalMigrationTargetState(
          cached: const [],
          pending: const [],
          stagedById: {stagedRecordId: staged()},
          requireAllCommitted: true,
        ),
        throwsFormatException,
      );
      expect(
        () => validateLocalMigrationTargetState(
          cached: [
            cached(
              recordId: stagedRecordId,
              operation: stagedOpId,
              commitSeq: null,
            ),
          ],
          pending: const [],
          stagedById: {stagedRecordId: staged()},
          requireAllCommitted: true,
        ),
        throwsFormatException,
      );
    },
  );

  test('rejects mismatched pending operations for a staged record', () {
    expect(
      () => validateLocalMigrationTargetState(
        cached: const [],
        pending: [
          pending(
            recordId: stagedRecordId,
            operation: extraOpId,
            json: envelopeJson(stagedRecordId, extraOpId),
          ),
        ],
        stagedById: {stagedRecordId: staged()},
      ),
      throwsFormatException,
    );
  });
}
