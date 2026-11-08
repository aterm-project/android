import 'dart:convert';

import 'package:aterm_client/archive/portable_vault_archive.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:flutter_test/flutter_test.dart';

const _recordId = '11111111-1111-4111-8111-111111111111';
const _operationId = '22222222-2222-4222-8222-222222222222';
const _revisionId = '33333333-3333-4333-8333-333333333333';
const _baseRevisionId = '44444444-4444-4444-8444-444444444444';
const _conflictId = '55555555-5555-4555-8555-555555555555';

void main() {
  test('base revision round-trips from the snapshot history', () {
    expect(
      () => PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: [_operation(baseRevisionId: _baseRevisionId)],
        conflicts: const [],
        snapshotRevisionIds: {_baseRevisionId},
      ),
      returnsNormally,
    );
  });

  test('outbox base outside history requires its signed base envelope', () {
    expect(
      () => PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: [_operation(baseRevisionId: _baseRevisionId)],
        conflicts: const [],
        snapshotRevisionIds: const {},
      ),
      throwsFormatException,
    );

    expect(
      () => PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: [
          _operation(
            baseRevisionId: _baseRevisionId,
            baseEnvelopeJson: _envelope(
              revisionId: _baseRevisionId,
              baseRevisionId: null,
            ),
          ),
        ],
        conflicts: const [],
        snapshotRevisionIds: const {},
      ),
      returnsNormally,
    );
  });

  test('base envelope must match its outbox record and revision', () {
    expect(
      () => PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: [
          _operation(
            baseRevisionId: _baseRevisionId,
            baseEnvelopeJson: jsonEncode({
              'header': {'record_id': _recordId, 'revision_id': _revisionId},
            }),
          ),
        ],
        conflicts: const [],
        snapshotRevisionIds: const {},
      ),
      throwsFormatException,
    );
  });

  test('transient CAS wait state cannot be exported without its journal', () {
    expect(
      () => PortableArchiveLocalStateValidator.validateForRoundTrip(
        operations: [_operation(status: 'cas_wait')],
        conflicts: const [],
        snapshotRevisionIds: const {},
      ),
      throwsFormatException,
    );
  });

  test(
    'resolution-pending branch links to its same-record outbox revision',
    () {
      final operation = _operation();
      expect(
        () => PortableArchiveLocalStateValidator.validateForRoundTrip(
          operations: [operation],
          conflicts: [
            _conflict(
              state: 'resolution_pending',
              resolutionOpId: _operationId,
              resolutionRevisionId: _revisionId,
            ),
          ],
          snapshotRevisionIds: const {},
        ),
        returnsNormally,
      );

      for (final invalid in [
        _conflict(
          state: 'resolution_pending',
          resolutionOpId: _operationId,
          resolutionRevisionId: _baseRevisionId,
        ),
        _conflict(
          state: 'resolution_pending',
          resolutionOpId: null,
          resolutionRevisionId: null,
        ),
        _conflict(
          state: 'open',
          resolutionOpId: _operationId,
          resolutionRevisionId: _revisionId,
        ),
      ]) {
        expect(
          () => PortableArchiveLocalStateValidator.validateForRoundTrip(
            operations: [operation],
            conflicts: [invalid],
            snapshotRevisionIds: const {},
          ),
          throwsFormatException,
        );
      }
    },
  );
}

ArchivePendingOperation _operation({
  String? opId = _operationId,
  String? recordId = _recordId,
  String? revisionId = _revisionId,
  String? baseRevisionId,
  String? baseEnvelopeJson,
  String status = 'queued',
}) => ArchivePendingOperation(
  opId: opId!,
  recordId: recordId!,
  baseRevisionId: baseRevisionId,
  baseEnvelopeJson: baseEnvelopeJson,
  envelopeJson: _envelope(
    opId: opId,
    recordId: recordId,
    revisionId: revisionId!,
    baseRevisionId: baseRevisionId,
  ),
  status: status,
  attemptCount: 0,
  createdAt: 1,
  lastAttemptAt: null,
);

ArchiveConflictBranch _conflict({
  String state = 'open',
  String? resolutionOpId,
  String? resolutionRevisionId,
}) => ArchiveConflictBranch(
  conflictId: _conflictId,
  recordId: _recordId,
  kind: 'concurrent_edit',
  branchEnvelopeJson: '{}',
  remoteEnvelopeJson: '{}',
  state: state,
  resolutionOpId: resolutionOpId,
  resolutionRevisionId: resolutionRevisionId,
  createdAt: 1,
);

String _envelope({
  String opId = _operationId,
  String recordId = _recordId,
  required String revisionId,
  String? baseRevisionId,
}) => jsonEncode({
  'header': {
    'op_id': opId,
    'record_id': recordId,
    'revision_id': revisionId,
    'base_revision_id': baseRevisionId,
  },
});
