import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = <String, dynamic>{
    'instance_id': '11111111-1111-4111-8111-111111111111',
    'server_space_id': '22222222-2222-4222-8222-222222222222',
    'generation': '1',
    'protocol_version': 1,
    'setup_required': false,
    'capabilities': <String>['snapshots'],
  };

  test('reads restore retention from top-level or limits capability', () {
    expect(
      InstanceInfo.fromJson({
        ...base,
        'restore_retention_days': 30,
      }).restoreRetentionDays,
      30,
    );
    expect(
      InstanceInfo.fromJson({
        ...base,
        'limits': {'restore_retention_days': 45},
      }).restoreRetentionDays,
      45,
    );
    expect(InstanceInfo.fromJson(base).restoreRetentionDays, isNull);
  });

  test('rejects invalid restore retention advertisements', () {
    for (final value in [0, -1, 36501, '30', 1.5]) {
      expect(
        () => InstanceInfo.fromJson({...base, 'restore_retention_days': value}),
        throwsFormatException,
      );
    }
  });

  test(
    'reads a delete revision absolute deadline and accepts legacy omission',
    () {
      final legacy = VaultRevisionEntry.fromJson(_deleteRevision());
      expect(legacy.restoreUntil, isNull);
      expect(legacy.autoPurgeEnabled, isFalse);
      expect(legacy.autoPurgeRevision, '0');

      final current = VaultRevisionEntry.fromJson({
        ..._deleteRevision(),
        'restore_until': '2026-10-31T12:00:00Z',
        'auto_purge_enabled': true,
        'auto_purge_revision': '4',
      });
      expect(current.restoreUntil, DateTime.utc(2026, 10, 31, 12));
      expect(current.autoPurgeEnabled, isTrue);
      expect(current.autoPurgeRevision, '4');
    },
  );

  test('accepts null deadlines on non-delete and redacted history rows', () {
    final update = VaultRevisionEntry.fromJson({
      ..._deleteRevision(operation: 'update', deleted: false),
      'restore_until': null,
    });
    expect(update.restoreUntil, isNull);

    final redacted = VaultRevisionEntry.fromJson({
      ..._deleteRevision(operation: 'redacted', deleted: false),
      'envelope': null,
      'redaction': <String, dynamic>{},
      'restore_until': null,
    });
    expect(redacted.restoreUntil, isNull);
  });

  test('rejects malformed, non-UTC, or non-delete restore deadlines', () {
    for (final value in [
      null,
      30,
      '2026-10-31T12:00:00',
      '2026-10-31T12:00:00+01:00',
      '2026-02-30T12:00:00Z',
    ]) {
      expect(
        () => VaultRevisionEntry.fromJson({
          ..._deleteRevision(),
          'restore_until': value,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => VaultRevisionEntry.fromJson({
        ..._deleteRevision(operation: 'update', deleted: false),
        'restore_until': '2026-10-31T12:00:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => VaultRevisionEntry.fromJson({
        ..._deleteRevision(deleted: false),
        'restore_until': '2026-10-31T12:00:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => VaultRevisionEntry.fromJson({
        ..._deleteRevision(operation: 'redacted', deleted: false),
        'envelope': null,
        'redaction': <String, dynamic>{},
        'restore_until': '2026-10-31T12:00:00Z',
      }),
      throwsFormatException,
    );
  });

  test(
    'rejects malformed automatic purge state and non-delete policy fields',
    () {
      for (final fields in [
        {'auto_purge_enabled': 'true'},
        {'auto_purge_revision': 1},
        {'auto_purge_revision': '00'},
      ]) {
        expect(
          () => VaultRevisionEntry.fromJson({..._deleteRevision(), ...fields}),
          throwsFormatException,
        );
      }
      expect(
        () => VaultRevisionEntry.fromJson({
          ..._deleteRevision(operation: 'update', deleted: false),
          'auto_purge_enabled': true,
        }),
        throwsFormatException,
      );
    },
  );
}

Map<String, dynamic> _deleteRevision({
  String operation = 'delete',
  bool deleted = true,
}) => {
  'record_id': '33333333-3333-4333-8333-333333333333',
  'revision_id': '44444444-4444-4444-8444-444444444444',
  'base_revision_id': '55555555-5555-4555-8555-555555555555',
  'commit_seq': '2',
  'operation': operation,
  'deleted': deleted,
  'created_at': '2026-10-01T12:00:00Z',
  'envelope': <String, dynamic>{},
};
