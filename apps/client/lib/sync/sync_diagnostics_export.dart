import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// A deliberately small, anonymous support report.
///
/// Keep this model independent of account, Vault, server, device, host and
/// record models. Adding fields here requires updating the privacy tests and
/// the diagnostics allowlist in the project plan.
class SyncDiagnosticsExport {
  SyncDiagnosticsExport._({
    required this.diagnosticId,
    required this.errorCode,
    required this.clientVersion,
    required this.pendingCount,
    required this.receivedCount,
    required this.conflictCount,
    required this.unavailableRecordCount,
    required this.exportedDayUtc,
    required this.lastSuccessDayUtc,
  });

  static const int maxBytes = 2048;
  static const int _maxCount = 1000000;
  static const Uuid _uuid = Uuid();
  static final RegExp _versionPattern = RegExp(
    r'^\d{1,6}\.\d{1,6}\.\d{1,6}(?:-[0-9A-Za-z.-]{1,24})?(?:\+[0-9A-Za-z.-]{1,24})?$',
  );

  final String diagnosticId;
  final String errorCode;
  final String clientVersion;
  final int pendingCount;
  final int receivedCount;
  final int conflictCount;
  final int unavailableRecordCount;
  final String exportedDayUtc;
  final String? lastSuccessDayUtc;

  factory SyncDiagnosticsExport.create({
    required String syncStatus,
    bool generationChanged = false,
    required int pendingCount,
    required int receivedCount,
    required int conflictCount,
    required int unavailableRecordCount,
    required DateTime? lastSuccessfulSyncAt,
    required String clientVersion,
    DateTime? now,
  }) {
    final exportedAt = (now ?? DateTime.now()).toUtc();
    final successAt = lastSuccessfulSyncAt?.toUtc();
    return SyncDiagnosticsExport._(
      diagnosticId: _uuid.v4(),
      errorCode: _errorCode(syncStatus, generationChanged: generationChanged),
      clientVersion: _safeClientVersion(clientVersion),
      pendingCount: _boundedCount(pendingCount),
      receivedCount: _boundedCount(receivedCount),
      conflictCount: _boundedCount(conflictCount),
      unavailableRecordCount: _boundedCount(unavailableRecordCount),
      exportedDayUtc: _day(exportedAt),
      lastSuccessDayUtc: successAt == null ? null : _day(successAt),
    );
  }

  Map<String, Object?> toJson() => {
    'diagnostic_id': diagnosticId,
    'error_code': errorCode,
    'client_version': clientVersion,
    'counts': {
      'pending': pendingCount,
      'received': receivedCount,
      'conflicts': conflictCount,
      'unavailable_cached_records': unavailableRecordCount,
    },
    'times': {
      'exported_day_utc': exportedDayUtc,
      'last_success_day_utc': lastSuccessDayUtc,
    },
  };

  Uint8List toBytes() {
    final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(toJson())}\n'));
    if (bytes.length > maxBytes) {
      throw StateError('Anonymous sync diagnostics exceeded the size limit.');
    }
    return bytes;
  }

  static int _boundedCount(int value) => value.clamp(0, _maxCount).toInt();

  static String _safeClientVersion(String value) =>
      _versionPattern.hasMatch(value) ? value : 'unknown';

  static String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _errorCode(String status, {required bool generationChanged}) {
    if (generationChanged) return 'GENERATION_MISMATCH';
    return switch (status) {
      'idle' => 'NONE',
      'pending' => 'SYNC_PENDING',
      'syncing' => 'SYNC_IN_PROGRESS',
      'retry_wait' => 'RETRY_QUEUED',
      'offline' => 'NETWORK_UNAVAILABLE',
      'error' => 'SYNC_ERROR',
      'auth_required' => 'AUTH_REQUIRED',
      'read_only' => 'READ_ONLY',
      'deletion_pending' => 'VAULT_DELETION_PENDING',
      'revoked' => 'DEVICE_REVOKED',
      'resnapshot_required' || 'snapshot_recovering' => 'SNAPSHOT_REQUIRED',
      'epoch_update_required' => 'KEY_UPDATE_REQUIRED',
      _ => 'OTHER_SYNC_ISSUE',
    };
  }
}
