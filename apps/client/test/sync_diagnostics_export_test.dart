import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_diagnostics_export.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnostics JSON is a bounded allowlist with redacted times', () {
    final now = DateTime.utc(2026, 10, 8, 14, 37, 42, 123, 456);
    final report = SyncDiagnosticsExport.create(
      syncStatus: 'PRIVATE_ERROR_REQUEST_ID_SENTINEL',
      pendingCount: 1000001,
      receivedCount: -12,
      conflictCount: 7,
      unavailableRecordCount: 2,
      lastSuccessfulSyncAt: DateTime.utc(2026, 10, 7, 23, 59, 59, 999),
      clientVersion: '0.1.0+1',
      now: now,
    );
    final secondReport = SyncDiagnosticsExport.create(
      syncStatus: 'PRIVATE_ERROR_REQUEST_ID_SENTINEL',
      pendingCount: 0,
      receivedCount: 0,
      conflictCount: 0,
      unavailableRecordCount: 0,
      lastSuccessfulSyncAt: null,
      clientVersion: '0.1.0+1',
      now: now,
    );
    final json = report.toJson();
    final counts = json['counts']! as Map<String, Object?>;
    final times = json['times']! as Map<String, Object?>;
    final bytes = report.toBytes();
    final serialized = utf8.decode(bytes);

    expect(
      json.keys,
      unorderedEquals([
        'diagnostic_id',
        'error_code',
        'client_version',
        'counts',
        'times',
      ]),
    );
    expect(
      counts.keys,
      unorderedEquals([
        'pending',
        'received',
        'conflicts',
        'unavailable_cached_records',
      ]),
    );
    expect(
      times.keys,
      unorderedEquals(['exported_day_utc', 'last_success_day_utc']),
    );
    expect(json['diagnostic_id'], isNot(secondReport.diagnosticId));
    expect(json['error_code'], 'OTHER_SYNC_ISSUE');
    expect(json['client_version'], '0.1.0+1');
    expect(counts, {
      'pending': 1000000,
      'received': 0,
      'conflicts': 7,
      'unavailable_cached_records': 2,
    });
    expect(times, {
      'exported_day_utc': '2026-10-08',
      'last_success_day_utc': '2026-10-07',
    });
    expect(bytes.length, lessThanOrEqualTo(SyncDiagnosticsExport.maxBytes));
    expect(serialized, isNot(contains('PRIVATE_ERROR_REQUEST_ID_SENTINEL')));
    expect(serialized, isNot(contains('14:37:42')));
    expect(serialized, isNot(contains('123456')));
  });

  test('known sync states map only to fixed diagnostic error codes', () {
    const knownStates = {
      'idle': 'NONE',
      'offline': 'NETWORK_UNAVAILABLE',
      'auth_required': 'AUTH_REQUIRED',
      'resnapshot_required': 'SNAPSHOT_REQUIRED',
      'snapshot_recovering': 'SNAPSHOT_REQUIRED',
      'epoch_update_required': 'KEY_UPDATE_REQUIRED',
      'revoked': 'DEVICE_REVOKED',
    };
    for (final entry in knownStates.entries) {
      final report = SyncDiagnosticsExport.create(
        syncStatus: entry.key,
        pendingCount: 0,
        receivedCount: 0,
        conflictCount: 0,
        unavailableRecordCount: 0,
        lastSuccessfulSyncAt: null,
        clientVersion: 'not-a-version-PRIVATE_SENTINEL',
        now: DateTime.utc(2026),
      );
      expect(report.toJson()['error_code'], entry.value, reason: entry.key);
      expect(report.toJson()['client_version'], 'unknown');
      expect(
        utf8.decode(report.toBytes()),
        isNot(contains('PRIVATE_SENTINEL')),
      );
    }
  });

  test(
    'generation mismatch is a fixed code without exporting generation IDs',
    () {
      final report = SyncDiagnosticsExport.create(
        syncStatus: 'idle',
        generationChanged: true,
        pendingCount: 0,
        receivedCount: 0,
        conflictCount: 0,
        unavailableRecordCount: 0,
        lastSuccessfulSyncAt: null,
        clientVersion: '0.1.0+1',
        now: DateTime.utc(2026),
      );

      expect(report.toJson()['error_code'], 'GENERATION_MISMATCH');
      expect(utf8.decode(report.toBytes()), isNot(contains('generation')));
    },
  );

  testWidgets('diagnostics are saved only after explicit export tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sync
          ..activeVault = const VaultDescriptor(
            id: 'PRIVATE_VAULT_ID_SENTINEL',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..syncStatus = 'PRIVATE_SERVER_ERROR_DETAIL_SENTINEL'
          ..pendingCount = 4
          ..receivedCount = 8
          ..unavailableRecordCount = 3
          ..lastSuccessfulSyncAt = DateTime.utc(2026, 10, 7, 15, 42, 51, 789)
          ..instance = const InstanceInfo(
            instanceId: 'PRIVATE_INSTANCE_ID_SENTINEL',
            serverSpaceId: 'PRIVATE_SERVER_SPACE_ID_SENTINEL',
            generation: 'PRIVATE_GENERATION_SENTINEL',
            protocolVersion: 1,
            setupRequired: false,
            capabilities: [],
          )
          ..syncCheckpointServerGeneration = 'PRIVATE_GENERATION_SENTINEL'
          ..openConflicts = [
            {
              'conflict_id': 'PRIVATE_CONFLICT_ID_SENTINEL',
              'record_id': 'PRIVATE_RECORD_ID_SENTINEL',
              'branch_envelope': {
                'header': {'revision_id': 'PRIVATE_REVISION_ID_SENTINEL'},
              },
              'remote_envelope': {
                'header': {'revision_id': 'PRIVATE_REMOTE_REVISION_SENTINEL'},
              },
            },
          ];
    final picker = _RecordingFilePicker();
    FilePicker? originalPicker;
    try {
      try {
        originalPicker = FilePicker.platform;
      } on Object {
        // Standalone Flutter tests may not have a native file picker set up.
      }
      FilePicker.platform = picker;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );

      expect(picker.saveCalls, 0);
      final exportButton = find.text('Export diagnostics');
      await tester.ensureVisible(exportButton);
      await tester.tap(exportButton);
      await tester.pumpAndSettle();

      expect(picker.saveCalls, 1);
      expect(picker.savedFileName, 'atermius-sync-diagnostics.json');
      final bytes = picker.savedBytes;
      expect(bytes, isNotNull);
      final serialized = utf8.decode(bytes!);
      final json = jsonDecode(serialized) as Map<String, dynamic>;
      expect(json['error_code'], 'OTHER_SYNC_ISSUE');
      expect(json['client_version'], matches(RegExp(r'^\d+\.\d+\.\d+\+\d+$')));
      expect(json['counts'], {
        'pending': 4,
        'received': 8,
        'conflicts': 1,
        'unavailable_cached_records': 3,
      });
      expect(
        json.keys,
        unorderedEquals([
          'diagnostic_id',
          'error_code',
          'client_version',
          'counts',
          'times',
        ]),
      );
      for (final secret in [
        'PRIVATE_VAULT_ID_SENTINEL',
        'PRIVATE_SERVER_ERROR_DETAIL_SENTINEL',
        'PRIVATE_GENERATION_SENTINEL',
        'PRIVATE_INSTANCE_ID_SENTINEL',
        'PRIVATE_SERVER_SPACE_ID_SENTINEL',
        'PRIVATE_CONFLICT_ID_SENTINEL',
        'PRIVATE_RECORD_ID_SENTINEL',
        'PRIVATE_REVISION_ID_SENTINEL',
        'PRIVATE_REMOTE_REVISION_SENTINEL',
        'instance-1',
        'space-1',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
      expect(serialized, isNot(contains('15:42:51')));
      expect(serialized, contains('2026-10-07'));
      expect(find.text('Anonymous sync diagnostics exported.'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (originalPicker != null) FilePicker.platform = originalPicker;
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

class _RecordingFilePicker extends FilePicker {
  int saveCalls = 0;
  String? savedFileName;
  Uint8List? savedBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saveCalls++;
    savedFileName = fileName;
    savedBytes = bytes == null ? null : Uint8List.fromList(bytes);
    return '/tmp/atermius-diagnostics-test.json';
  }
}
