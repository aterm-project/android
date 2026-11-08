import 'dart:convert';

import 'models.dart';

const int shellHistoryMaxCommandBytes = 4096;
const int _maxSafeShellHistoryTimestamp = 8640000000000000;
const String _canonicalUuidPattern =
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

/// A completed shell command stored as an encrypted Vault record.
///
/// All command details, host references, timestamps, and source-device IDs
/// belong in the encrypted record payload. The server sees only the usual
/// record envelope and record ID.
final class ShellHistoryRecord {
  ShellHistoryRecord({
    required this.id,
    required this.hostRecordId,
    required this.command,
    required this.exitStatus,
    required this.startedAtMs,
    required this.completedAtMs,
    required this.sourceDeviceId,
  }) {
    _validateUuid(id, 'id');
    _validateUuid(hostRecordId, 'host_record_id');
    _validateUuid(sourceDeviceId, 'source_device_id');
    _validateCommand(command);
    _validateStatus(exitStatus);
    _validateTimestamp(startedAtMs, 'started_at_ms');
    _validateTimestamp(completedAtMs, 'completed_at_ms');
    if (completedAtMs < startedAtMs) {
      throw const FormatException(
        'completed_at_ms must not be earlier than started_at_ms',
      );
    }
  }

  final String id;
  final String hostRecordId;
  final String command;
  final int exitStatus;
  final int startedAtMs;
  final int completedAtMs;
  final String sourceDeviceId;

  static const String format = 'atermius-shell-history';
  static const int version = 1;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': RecordKind.shellHistory.name,
    'format': format,
    'version': version,
    'host_record_id': hostRecordId,
    'command': command,
    'exit_status': exitStatus,
    'started_at_ms': startedAtMs,
    'completed_at_ms': completedAtMs,
    'source_device_id': sourceDeviceId,
  };

  /// Decodes the exact v1 payload. Repository metadata is accepted for
  /// `SyncRepository.loadRecords()` rows but is not re-emitted by [toJson].
  factory ShellHistoryRecord.fromJson(Map<String, dynamic> json) {
    const requiredFields = {
      'id',
      'type',
      'format',
      'version',
      'host_record_id',
      'command',
      'exit_status',
      'started_at_ms',
      'completed_at_ms',
      'source_device_id',
    };
    const repositoryFields = {'_record_id', '_revision_id'};
    if (json.keys.any((key) => key is! String)) {
      throw const FormatException('Shell history record keys must be strings');
    }
    final keys = json.keys.cast<String>().toSet();
    if (!keys.containsAll(requiredFields) ||
        keys.any(
          (field) =>
              !requiredFields.contains(field) &&
              !repositoryFields.contains(field),
        )) {
      throw const FormatException(
        'Shell history record fields are incomplete or unknown',
      );
    }
    if (json['type'] != RecordKind.shellHistory.name) {
      throw const FormatException('Record type must be shellHistory');
    }
    if (json['format'] != format || json['version'] != version) {
      throw const FormatException('Shell history record format is unsupported');
    }

    final id = _requiredString(json['id'], 'id');
    _validateUuid(id, 'id');
    if (json.containsKey('_record_id')) {
      final repositoryId = _requiredString(json['_record_id'], '_record_id');
      _validateUuid(repositoryId, '_record_id');
      if (repositoryId != id) {
        throw const FormatException(
          'Shell history payload ID does not match record ID',
        );
      }
    }
    if (json.containsKey('_revision_id') && json['_revision_id'] != null) {
      _validateUuid(
        _requiredString(json['_revision_id'], '_revision_id'),
        '_revision_id',
      );
    }

    return ShellHistoryRecord(
      id: id,
      hostRecordId: _requiredString(json['host_record_id'], 'host_record_id'),
      command: _requiredString(json['command'], 'command'),
      exitStatus: _requiredInt(json['exit_status'], 'exit_status'),
      startedAtMs: _requiredInt(json['started_at_ms'], 'started_at_ms'),
      completedAtMs: _requiredInt(json['completed_at_ms'], 'completed_at_ms'),
      sourceDeviceId: _requiredString(
        json['source_device_id'],
        'source_device_id',
      ),
    );
  }
}

String _requiredString(Object? value, String field) {
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

int _requiredInt(Object? value, String field) {
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

void _validateUuid(String value, String field) {
  if (!RegExp(_canonicalUuidPattern).hasMatch(value)) {
    throw FormatException('$field must be a lowercase canonical UUID');
  }
}

void _validateCommand(String value) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty || bytes.length > shellHistoryMaxCommandBytes) {
    throw const FormatException('command must contain 1 to 4096 UTF-8 bytes');
  }
  for (final rune in value.runes) {
    if (rune == 0 ||
        rune == 0x1b ||
        rune == 0x7f ||
        (rune < 0x20 && rune != 0x09 && rune != 0x0a) ||
        (rune >= 0x80 && rune <= 0x9f)) {
      throw const FormatException(
        'command contains a forbidden control character',
      );
    }
  }
}

void _validateStatus(int value) {
  if (value < 0 || value > 255) {
    throw const FormatException('exit_status must be between 0 and 255');
  }
}

void _validateTimestamp(int value, String field) {
  if (value < 0 || value > _maxSafeShellHistoryTimestamp) {
    throw FormatException(
      '$field is outside the supported UTC millisecond range',
    );
  }
}
