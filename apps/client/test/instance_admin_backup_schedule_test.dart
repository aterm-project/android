import 'support/settings_navigation.dart';

import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'schedule GET is authenticated and parses the exact response shape',
    () async {
      late http.Request captured;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_enabledSchedule),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final schedule = await api.instanceAdminBackupSchedule();
        expect(captured.method, 'GET');
        expect(captured.url.path, '/prefix/api/v1/admin/backup-schedule');
        expect(
          captured.headers['authorization'],
          'Bearer session-access-token',
        );
        expect(schedule.backupConfigured, isTrue);
        expect(schedule.enabled, isTrue);
        expect(schedule.intervalHours, 24);
        expect(schedule.nextRunAt, DateTime.utc(2026, 10, 3, 12));
        expect(schedule.lastRun?.runId, '52ec5f6a-8db7-4162-99bb-d4ee6e933bbd');
        expect(schedule.lastRun?.status, 'succeeded');
        expect(schedule.lastRun?.archiveBytes, 4096);
        expect(schedule.lastRun?.migrationVersion, 23);
      } finally {
        api.close();
      }
    },
  );

  test(
    'schedule PUT sends only interval_hours and accepts null to disable',
    () async {
      late http.Request captured;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_disabledSchedule),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final schedule = await api.updateInstanceAdminBackupSchedule(null);
        expect(captured.method, 'PUT');
        expect(captured.url.path, '/prefix/api/v1/admin/backup-schedule');
        expect(
          captured.headers['authorization'],
          'Bearer session-access-token',
        );
        expect(jsonDecode(captured.body), {'interval_hours': null});
        expect(schedule.enabled, isFalse);
        expect(schedule.nextRunAt, isNull);
      } finally {
        api.close();
      }
    },
  );

  test(
    'schedule PUT rejects intervals outside the server range locally',
    () async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      try {
        await expectLater(
          api.updateInstanceAdminBackupSchedule(0),
          throwsArgumentError,
        );
        await expectLater(
          api.updateInstanceAdminBackupSchedule(721),
          throwsArgumentError,
        );
        expect(requests, 0);
      } finally {
        api.close();
      }
    },
  );

  test(
    'schedule parser rejects extra keys, invalid intervals and run states',
    () {
      expect(
        InstanceAdminBackupSchedule.fromJson(_disabledSchedule).enabled,
        isFalse,
      );
      expect(
        () => InstanceAdminBackupSchedule.fromJson({
          ..._disabledSchedule,
          'archive_path': '/private/backups',
        }),
        throwsFormatException,
      );
      for (final interval in [0, 721, '24', true]) {
        expect(
          () => InstanceAdminBackupSchedule.fromJson({
            ..._disabledSchedule,
            'interval_hours': interval,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => InstanceAdminBackupSchedule.fromJson({
          ..._disabledSchedule,
          'backup_configured': 'ready',
        }),
        throwsFormatException,
      );
      final invalidRun = jsonDecode(jsonEncode(_enabledSchedule)) as Map;
      (invalidRun['last_run'] as Map)['status'] = 'unknown';
      expect(
        () => InstanceAdminBackupSchedule.fromJson(
          Map<String, dynamic>.from(invalidRun),
        ),
        throwsFormatException,
      );
      final secretRunField = jsonDecode(jsonEncode(_enabledSchedule)) as Map;
      (secretRunField['last_run'] as Map)['archive_path'] = '/private/key';
      expect(
        () => InstanceAdminBackupSchedule.fromJson(
          Map<String, dynamic>.from(secretRunField),
        ),
        throwsFormatException,
      );
    },
  );

  test('schedule parser enforces run ID and outcome consistency', () {
    for (final status in ['running', 'succeeded', 'failed', 'interrupted']) {
      expect(
        InstanceAdminBackupSchedule.fromJson({
          ..._enabledSchedule,
          'last_run': _runForStatus(status),
        }).lastRun?.status,
        status,
      );
    }

    final invalidRunId = _runForStatus('succeeded')
      ..['run_id'] = 'A2c91bda-8db7-4162-99bb-d4ee6e933bbd';
    final unknownResult = _runForStatus('succeeded')
      ..['result_code'] = '/private/archive.key';
    final missingSuccessDetails = _runForStatus('succeeded')
      ..['archive_bytes'] = null;
    final finishedRunning = _runForStatus('running')
      ..['finished_at'] = '2026-10-02T12:01:00Z';
    final failedWrongResult = _runForStatus('failed')
      ..['result_code'] = 'completed';

    for (final run in [
      invalidRunId,
      unknownResult,
      missingSuccessDetails,
      finishedRunning,
      failedWrongResult,
    ]) {
      expect(
        () => InstanceAdminBackupSchedule.fromJson({
          ..._enabledSchedule,
          'last_run': run,
        }),
        throwsFormatException,
      );
    }

    expect(
      () => InstanceAdminBackupSchedule.fromJson({
        ..._enabledSchedule,
        'interval_hours': null,
      }),
      throwsFormatException,
    );
    expect(
      () => InstanceAdminBackupSchedule.fromJson({
        ..._disabledSchedule,
        'interval_hours': 24,
      }),
      throwsFormatException,
    );
  });

  testWidgets('schedule controls are hidden from non-admin accounts', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Scheduled encrypted backups'), findsNothing);
      expect(find.text('Load backup schedule'), findsNothing);
      expect(harness.api.scheduleLoads, 0);
      expect(harness.api.scheduleSaves, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin can configure and then disable the backup interval', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.schedule = _disabledSchedule;
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup schedule'));
      await tester.tap(find.text('Load backup schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Server backup configuration ready'), findsOneWidget);
      expect(find.text('No scheduled backup runs recorded'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-enabled')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('admin-backup-schedule-interval')),
        '0',
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-save')),
      );
      await tester.pump();
      expect(find.text('Enter a whole number from 1 to 720.'), findsOneWidget);
      expect(harness.api.scheduleSaves, 0);

      await tester.enterText(
        find.byKey(const ValueKey('admin-backup-schedule-interval')),
        '720',
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-save')),
      );
      await tester.pumpAndSettle();
      expect(harness.api.lastSavedIntervalHours, 720);
      expect(find.text('Scheduled backup settings saved.'), findsOneWidget);
      expect(find.textContaining('Next run'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-enabled')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-save')),
      );
      await tester.pumpAndSettle();
      expect(harness.api.lastSavedIntervalHours, isNull);
      expect(find.text('Scheduled backups turned off.'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
      expect(harness.api.scheduleSaves, 2);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin sees next run and sanitized last-run details', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.schedule = _enabledSchedule;
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup schedule'));
      await tester.tap(find.text('Load backup schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Next run'), findsOneWidget);
      expect(find.text('Last run status'), findsOneWidget);
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.text('Scheduled for'), findsOneWidget);
      expect(find.text('Started at'), findsOneWidget);
      expect(find.text('Finished at'), findsOneWidget);
      expect(find.text('Migration version'), findsOneWidget);
      expect(find.text('23'), findsOneWidget);
      expect(find.textContaining('4.0 KiB (4,096 bytes)'), findsOneWidget);
      expect(find.text('completed'), findsNothing);
      expect(find.textContaining('52ec5f6a'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'configuration state and API errors stay accessible and private',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      harness.api.schedule = _unconfiguredSchedule;
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(find.text('Load backup schedule'));
        await tester.tap(find.text('Load backup schedule'));
        await tester.pumpAndSettle();
        expect(
          find.text('Server backup configuration not ready'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Ask the server operator to configure'),
          findsOneWidget,
        );
        final toggle = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('admin-backup-schedule-enabled')),
        );
        expect(toggle.onChanged, isNull);
        expect(find.textContaining('/private/'), findsNothing);
        expect(find.textContaining('backup.key'), findsNothing);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('server configuration errors do not reveal path details', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.schedule = _disabledSchedule;
    harness.api.scheduleSaveError = const ApiException(
      statusCode: 503,
      code: 'BACKUP_NOT_CONFIGURED',
      message: 'Invalid key path: /private/backup.key',
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup schedule'));
      await tester.tap(find.text('Load backup schedule'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-enabled')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('admin-backup-schedule-interval')),
        '24',
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-schedule-save')),
      );
      await tester.pumpAndSettle();
      expect(find.text("The server hasn't configured a usable encrypted backup destination and key; the scheduled backup wasn't changed."), findsOneWidget);
      expect(find.textContaining('/private/'), findsNothing);
      expect(find.textContaining('backup.key'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });
}

Future<void> _pumpSettings(WidgetTester tester, AppController app) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pump();
  if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
    await openSettingsCategory(tester, 'backup', ifAvailable: true);
  }
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _WidgetAdminApi api;
  final AppController app;

  static Future<_Harness> create({required bool isAdmin}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetAdminApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..adminMaintenanceJobsPage = AdminMaintenanceJobsPage(
            jobs: const [],
            total: 0,
            limit: 50,
            offset: 0,
            supportedActions: const [
              'maintenance',
              'backup',
              'restore',
              'backup_schedule',
            ],
          )
          ..account = AccountProfile(
            accountId: 'account-123',
            deviceId: 'device-456',
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
            policy: {'instance_admin': isAdmin},
          );
    return _Harness(database, api, app);
  }
}

class _WidgetAdminApi extends ApiClient {
  _WidgetAdminApi()
    : super(
        baseUrl: 'https://admin-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  Map<String, dynamic> schedule = _disabledSchedule;
  int scheduleLoads = 0;
  int scheduleSaves = 0;
  int? lastSavedIntervalHours;
  ApiException? scheduleSaveError;

  @override
  Future<InstanceAdminBackupSchedule> instanceAdminBackupSchedule() async {
    scheduleLoads++;
    return InstanceAdminBackupSchedule.fromJson(schedule);
  }

  @override
  Future<InstanceAdminBackupSchedule> updateInstanceAdminBackupSchedule(
    int? intervalHours,
  ) async {
    scheduleSaves++;
    lastSavedIntervalHours = intervalHours;
    if (scheduleSaveError case final error?) throw error;
    schedule = intervalHours == null
        ? _disabledSchedule
        : {
            ..._disabledSchedule,
            'interval_hours': intervalHours,
            'next_run_at': '2026-10-03T12:00:00Z',
          };
    return InstanceAdminBackupSchedule.fromJson(schedule);
  }
}

final _disabledSchedule = <String, dynamic>{
  'operation': 'backup_schedule',
  'backup_configured': true,
  'interval_hours': null,
  'next_run_at': null,
  'last_run': null,
};

final _unconfiguredSchedule = <String, dynamic>{
  ..._disabledSchedule,
  'backup_configured': false,
};

final _enabledSchedule = <String, dynamic>{
  'operation': 'backup_schedule',
  'backup_configured': true,
  'interval_hours': 24,
  'next_run_at': '2026-10-03T12:00:00Z',
  'last_run': {
    'run_id': '52ec5f6a-8db7-4162-99bb-d4ee6e933bbd',
    'scheduled_for': '2026-10-02T12:00:00Z',
    'started_at': '2026-10-02T12:00:04Z',
    'finished_at': '2026-10-02T12:00:12Z',
    'status': 'succeeded',
    'result_code': 'completed',
    'archive_bytes': 4096,
    'migration_version': 23,
  },
};

Map<String, dynamic> _runForStatus(String status) {
  final succeeded = status == 'succeeded';
  final running = status == 'running';
  return {
    'run_id': '52ec5f6a-8db7-4162-99bb-d4ee6e933bbd',
    'scheduled_for': '2026-10-02T12:00:00Z',
    'started_at': '2026-10-02T12:00:04Z',
    'finished_at': running ? null : '2026-10-02T12:00:12Z',
    'status': status,
    'result_code': switch (status) {
      'running' => null,
      'succeeded' => 'completed',
      'failed' => 'backup_failed',
      'interrupted' => 'interrupted',
      _ => null,
    },
    'archive_bytes': succeeded ? 4096 : null,
    'migration_version': succeeded ? 23 : null,
  };
}
