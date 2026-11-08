import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _conflictId = '55555555-5555-4555-8555-555555555555';
const _secondConflictId = '66666666-6666-4666-8666-666666666666';
const _resolvedConflictId = '77777777-7777-4777-8777-777777777777';
const _remoteConflictId = '88888888-8888-4888-8888-888888888888';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _generation = '99999999-9999-4999-8999-999999999999';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local duplicate stays out of the inbox and count ignores resolved feed',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..openConflicts = [
              {'conflict_id': _conflictId, 'record_id': _recordId},
              {'conflict_id': _secondConflictId, 'record_id': _recordId},
            ]
            ..feedConflictItems = [
              _item(_conflictId),
              _item(_resolvedConflictId, resolutionState: 'resolved'),
            ];

      expect(app.openFeedConflictItems, isEmpty);
      expect(app.resolvedFeedConflictItems, hasLength(1));
      expect(app.unresolvedConflictCount, 2);

      app.dispose();
      await database.close();
    },
  );

  test(
    'local Workspace conflict keeps copy actions until feed resolves it',
    () {
      final projection = projectConflictReviewItems(
        localOpenConflictRecords: {
          _conflictId: _recordId,
          _secondConflictId: _recordId,
          _resolvedConflictId: _recordId,
        },
        feedItems: [
          _item(_conflictId),
          _item(_resolvedConflictId, resolved: true),
          _item(_remoteConflictId),
        ],
      );

      expect(
        projection.localConflictIds,
        containsAll([_conflictId, _secondConflictId]),
      );
      expect(projection.localConflictIds, isNot(contains(_resolvedConflictId)));
      expect(
        projection.feedItems.map((item) => item.conflictId),
        containsAll([_resolvedConflictId, _remoteConflictId]),
      );
      expect(
        projection.feedItems.map((item) => item.conflictId),
        isNot(contains(_conflictId)),
      );
    },
  );

  test(
    'same conflict ID on a different record remains independently visible',
    () {
      const unrelatedRecordId = '44444444-4444-4444-8444-444444444444';
      final projection = projectConflictReviewItems(
        localOpenConflictRecords: {_conflictId: _recordId},
        feedItems: [_item(_conflictId, recordId: unrelatedRecordId)],
      );

      expect(projection.localConflictIds, contains(_conflictId));
      expect(projection.feedItems, hasLength(1));
      expect(projection.feedItems.single.recordId, unrelatedRecordId);
    },
  );

  test('an ID collision is counted once for each distinct record', () async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..openConflicts = [
            {'conflict_id': _conflictId, 'record_id': _recordId},
          ]
          ..feedConflictItems = [
            _item(_conflictId, recordId: _secondConflictId),
          ];

    expect(app.unresolvedConflictCount, 2);

    app.dispose();
    await database.close();
  });
}

ConflictFeedReviewItem _item(
  String conflictId, {
  String recordId = _recordId,
  bool resolved = false,
  String? resolutionState,
}) => ConflictFeedReviewItem(
  conflictId: conflictId,
  recordId: recordId,
  seq: '1',
  createdAt: '2026-09-27T12:30:00Z',
  serverGeneration: _generation,
  partitionId: 'partition',
  baseRevisionId: null,
  branchRevisionId: null,
  branchDeviceId: null,
  branchOperation: null,
  keyEpoch: null,
  membershipVersion: null,
  currentHeadRevisionId: null,
  currentHeadExists: false,
  currentHeadDeleted: false,
  currentHeadCommitted: false,
  isVerified: false,
  verificationError: null,
  isResolved: resolved,
  resolutionState: resolutionState ?? (resolved ? 'resolved' : null),
);
