import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/shell_history_record.dart';

void main() {
  const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const hostId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const deviceId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  ShellHistoryRecord create({
    String recordId = id,
    String hostRecordId = hostId,
    String command = 'printf "hello"',
    int exitStatus = 0,
    int startedAtMs = 1000,
    int completedAtMs = 1250,
    String sourceDeviceId = deviceId,
  }) => ShellHistoryRecord(
    id: recordId,
    hostRecordId: hostRecordId,
    command: command,
    exitStatus: exitStatus,
    startedAtMs: startedAtMs,
    completedAtMs: completedAtMs,
    sourceDeviceId: sourceDeviceId,
  );

  group('ShellHistoryRecord', () {
    test('round trips the strict versioned encrypted payload', () {
      final record = create(command: 'echo 雪', exitStatus: 7);
      final payload = record.toJson();

      expect(RecordKind.shellHistory.name, 'shellHistory');
      expect(payload, {
        'id': id,
        'type': 'shellHistory',
        'format': 'atermius-shell-history',
        'version': 1,
        'host_record_id': hostId,
        'command': 'echo 雪',
        'exit_status': 7,
        'started_at_ms': 1000,
        'completed_at_ms': 1250,
        'source_device_id': deviceId,
      });

      final decoded = ShellHistoryRecord.fromJson(payload);
      expect(decoded.toJson(), payload);
      expect(decoded.id, id);
      expect(decoded.hostRecordId, hostId);
      expect(decoded.command, 'echo 雪');
      expect(decoded.exitStatus, 7);
      expect(decoded.startedAtMs, 1000);
      expect(decoded.completedAtMs, 1250);
      expect(decoded.sourceDeviceId, deviceId);
    });

    test('accepts matching encrypted-record repository metadata', () {
      final decoded = ShellHistoryRecord.fromJson({
        ...create().toJson(),
        '_record_id': id,
        '_revision_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      });
      expect(decoded.id, id);
      expect(decoded.toJson().keys, isNot(contains('_revision_id')));
    });

    test('rejects missing, unknown, or unsupported format fields', () {
      final payload = create().toJson();
      expect(
        () => ShellHistoryRecord.fromJson({...payload}..remove('command')),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({...payload, 'unexpected': true}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({...payload, 'type': 'preference'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({...payload, 'format': 'other'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({...payload, 'version': 2}),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires canonical UUIDs and matching record identity', () {
      expect(
        () => create(recordId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => create(hostRecordId: 'host-local-id'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => create(sourceDeviceId: 'not-a-uuid'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({
          ...create().toJson(),
          '_record_id': hostId,
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({
          ...create().toJson(),
          '_revision_id': 'not-a-uuid',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('bounds command text and rejects terminal control characters', () {
      expect(() => create(command: ''), throwsA(isA<FormatException>()));
      expect(
        () => create(
          command: List.filled(shellHistoryMaxCommandBytes + 1, 'x').join(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => create(command: 'echo\u001b[31msecret'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => create(command: 'echo\u0000secret'),
        throwsA(isA<FormatException>()),
      );
      expect(() => create(command: 'echo\t雪\n'), returnsNormally);
    });

    test('validates exit status and ordered UTC millisecond timestamps', () {
      expect(() => create(exitStatus: -1), throwsA(isA<FormatException>()));
      expect(() => create(exitStatus: 256), throwsA(isA<FormatException>()));
      expect(() => create(startedAtMs: -1), throwsA(isA<FormatException>()));
      expect(() => create(completedAtMs: 999), throwsA(isA<FormatException>()));
      expect(
        () => create(completedAtMs: 8640000000000001),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-integer numeric fields', () {
      expect(
        () => ShellHistoryRecord.fromJson({
          ...create().toJson(),
          'exit_status': 0.0,
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShellHistoryRecord.fromJson({
          ...create().toJson(),
          'started_at_ms': '1000',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
