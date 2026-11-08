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

const _jobId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _requestId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _backupJobId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _backupRequestId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('admin jobs API uses authenticated paginated routes', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://admin-jobs.example.test/prefix',
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'jobs': [_jobJson()],
              'total': 1,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'job': _jobJson(
              status: 'queued',
              action: body['action']! as String,
              requestId: body['request_id']! as String,
            ),
          }),
          202,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-token';
    try {
      final page = await api.adminMaintenanceJobs(limit: 50, offset: 100);
      expect(page.total, 1);
      expect(page.offset, 100);
      expect(page.jobs.single.status, 'succeeded');
      expect(page.supportedActions, isEmpty);
      final accepted = await api.startAdminMaintenanceJob(
        requestId: _requestId,
      );
      expect(accepted.status, 'queued');
      final backup = await api.startAdminBackupJob(requestId: _backupRequestId);
      expect(backup.action, 'backup');
      expect(requests.map((request) => request.method), [
        'GET',
        'POST',
        'POST',
      ]);
      expect(requests[0].url.path, '/prefix/api/v1/admin/jobs');
      expect(requests[0].url.queryParameters, {'limit': '50', 'offset': '100'});
      expect(requests[0].headers['authorization'], 'Bearer session-token');
      expect(requests[1].url.path, '/prefix/api/v1/admin/jobs');
      expect(requests[1].headers['authorization'], 'Bearer session-token');
      expect(jsonDecode(requests[1].body), {
        'request_id': _requestId,
        'action': 'maintenance',
      });
      expect(requests[2].url.path, '/prefix/api/v1/admin/jobs');
      expect(requests[2].headers['authorization'], 'Bearer session-token');
      expect(jsonDecode(requests[2].body), {
        'request_id': _backupRequestId,
        'action': 'backup',
      });
    } finally {
      api.close();
    }
  });

  test('admin job parser rejects unsafe, unknown, and inconsistent states', () {
    expect(
      () => AdminMaintenanceJob.fromJson({..._jobJson(), 'action': 'unknown'}),
      throwsFormatException,
    );
    expect(
      AdminMaintenanceJob.fromJson(
        _jobJson(
          status: 'succeeded',
          action: 'backup',
          jobId: _backupJobId,
          requestId: _backupRequestId,
        ),
      ).action,
      'backup',
    );
    final completedBackup = AdminMaintenanceJob.fromJson(
      _jobJson(
        status: 'succeeded',
        action: 'backup',
        jobId: _backupJobId,
        requestId: _backupRequestId,
      )..['archive_id'] = _backupJobId,
    );
    expect(completedBackup.archiveId, _backupJobId);
    expect(completedBackup.archiveSource, isNull);
    expect(
      () => AdminMaintenanceJob.fromJson(
        _jobJson(
          status: 'succeeded',
          action: 'backup',
          jobId: _backupJobId,
          requestId: _backupRequestId,
        )..['archive_source'] = 'local',
      ),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJob.fromJson(
        _jobJson(
          status: 'succeeded',
          action: 'backup',
          jobId: _backupJobId,
          requestId: _backupRequestId,
        )..['archive_id'] = '/tmp/archive',
      ),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJob.fromJson(
        _jobJson(status: 'succeeded', action: 'maintenance')
          ..['archive_id'] = _backupJobId,
      ),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJob.fromJson({
        ..._jobJson(
          status: 'failed',
          action: 'backup',
          jobId: _backupJobId,
          requestId: _backupRequestId,
        ),
        'result_code': 'maintenance_failed',
      }),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJob.fromJson({
        ..._jobJson(),
        'result_code': '/tmp/data',
      }),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJob.fromJson({
        ..._jobJson(status: 'running'),
        'finished_at': '2026-09-29T11:00:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => AdminMaintenanceJobsPage.fromJson(
        {
          'jobs': [_jobJson(), _jobJson()],
          'total': 2,
        },
        limit: 50,
        offset: 0,
      ),
      throwsFormatException,
    );
  });

  test('PG restore stage failures are accepted as safe job states', () {
    for (final stageStatus in ['failed', 'interrupted']) {
      final json =
          _jobJson(
              status: stageStatus,
              jobId: _jobId2,
              requestId: _backupRequestId,
              action: 'restore',
            )
            ..['archive_id'] = _backupJobId
            ..['archive_source'] = 'local'
            ..['restore_stage_status'] = stageStatus;
      expect(
        AdminMaintenanceJob.fromJson(json).restoreStageStatus,
        stageStatus,
      );
    }
  });

  test(
    'admin jobs page validates server capabilities for the active backend',
    () {
      final missingCapabilities = AdminMaintenanceJobsPage.fromJson(
        {'jobs': const [], 'total': 0},
        limit: 50,
        offset: 0,
      );
      expect(missingCapabilities.supportedActions, isEmpty);

      final page = AdminMaintenanceJobsPage.fromJson(
        {
          'jobs': const [],
          'total': 0,
          'supported_actions': const ['maintenance'],
        },
        limit: 50,
        offset: 0,
      );
      expect(page.supportedActions, ['maintenance']);
      final granularCapabilities = AdminMaintenanceJobsPage.fromJson(
        {
          'jobs': const [],
          'total': 0,
          'supported_actions': const [
            'maintenance',
            'backup',
            'restore',
            'backup_status',
            'backup_replication',
            'backup_schedule',
            'restore_replica',
            'restore_stage_discard',
          ],
        },
        limit: 50,
        offset: 0,
      );
      expect(
        granularCapabilities.supportedActions,
        containsAll([
          'backup_status',
          'backup_replication',
          'backup_schedule',
          'restore_replica',
          'restore_stage_discard',
        ]),
      );
      expect(
        () => AdminMaintenanceJobsPage.fromJson(
          {
            'jobs': const [],
            'total': 0,
            'supported_actions': const ['maintenance', 'shell'],
          },
          limit: 50,
          offset: 0,
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('maintenance jobs and controls are hidden for non-admins', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance jobs'), findsNothing);
      expect(find.text('Run encrypted backup'), findsNothing);
      expect(find.byTooltip('Load instance jobs'), findsNothing);
      expect(harness.api.pageRequests, isEmpty);
      expect(harness.api.startRequests, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('maintenance submission is blocked while backup is submitting', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.app.adminBackupJobSubmitting = true;
    try {
      expect(await harness.app.runAdminMaintenance(), isFalse);
      expect(harness.api.startRequests, isEmpty);
      expect(harness.api.backupRequests, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin can load jobs, run maintenance and refresh state', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.addAll([
      _page([_job(status: 'succeeded')]),
    ]);
    harness.api.pages.addAll([
      _page([
        _job(status: 'succeeded'),
        _job(status: 'running', jobId: _jobId2),
      ]),
    ]);
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();
      expect(find.text('Instance jobs'), findsOneWidget);
      expect(find.text('Maintenance · succeeded'), findsOneWidget);
      expect(harness.api.pageRequests, [(50, 0)]);

      await tester.ensureVisible(find.text('Run maintenance now'));
      await tester.tap(find.text('Run maintenance now'));
      await tester.pumpAndSettle();
      expect(harness.api.startRequests, hasLength(1));
      expect(
        harness.api.startRequests.single,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(harness.api.pageRequests, [(50, 0), (50, 0)]);
      expect(find.text('Maintenance job submitted. Refresh the job list to see its status.'), findsOneWidget);
      expect(find.text('Maintenance · running'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'PostgreSQL backup and restore capabilities hide SQLite-only panels',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.add(
        _page(const [], supportedActions: ['maintenance', 'backup', 'restore']),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Run encrypted backup'), findsOneWidget);
        expect(find.text('Prepare isolated restore copy'), findsOneWidget);
        expect(find.text('Instance backup status'), findsNothing);
        expect(find.text('Off-site encrypted backup copies'), findsNothing);
        expect(find.text('Scheduled encrypted backups'), findsNothing);
        expect(harness.api.localBackupEndpointRequests, isEmpty);
        expect(find.textContaining('remote replica'), findsNothing);
        expect(find.textContaining('Remote bytes'), findsNothing);
        harness.api.restoreSources = InstanceAdminRestoreSourcesPage(
          sources: [
            InstanceAdminRestoreSource(
              archiveId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              createdAt: DateTime.utc(2026, 10, 1),
              archiveBytes: 4096,
              origin: 'manual',
              source: 'local',
            ),
            InstanceAdminRestoreSource(
              archiveId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
              createdAt: DateTime.utc(2026, 10, 1),
              archiveBytes: 4096,
              origin: 'manual',
              source: 'replica',
            ),
          ],
          total: 2,
          limit: 50,
          offset: 0,
        );
        final loadSources = find.byKey(
          const ValueKey('admin-restore-source-load'),
        );
        await tester.ensureVisible(loadSources);
        await tester.tap(loadSources);
        await tester.pumpAndSettle();
        expect(harness.api.restoreSourceRequests, [0]);
        expect(harness.api.localBackupEndpointRequests, isEmpty);
        expect(
          find.byKey(
            const ValueKey(
              'admin-restore-source-option-local-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey(
              'admin-restore-source-option-replica-ffffffff-ffff-4fff-8fff-ffffffffffff',
            ),
          ),
          findsNothing,
        );
        expect(find.textContaining('remote replica'), findsNothing);
        expect(
          find.textContaining('PostgreSQL mode currently supports'),
          findsNothing,
        );
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('backup and restore panels follow separate advertised actions', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _page(const [], supportedActions: ['maintenance', 'restore']),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();
      expect(find.text('Prepare isolated restore copy'), findsOneWidget);
      expect(find.text('Run encrypted backup'), findsNothing);
      expect(find.text('Instance backup status'), findsNothing);
      expect(find.text('Scheduled encrypted backups'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'backup controls and local backup panels have separate capabilities',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.add(
        _page(const [], supportedActions: ['maintenance', 'backup']),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Run encrypted backup'), findsOneWidget);
        expect(find.text('Instance backup status'), findsNothing);
        expect(find.text('Off-site encrypted backup copies'), findsNothing);
        expect(find.text('Scheduled encrypted backups'), findsNothing);
        expect(find.text('Prepare isolated restore copy'), findsNothing);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('restore stage is hidden unless restore is advertised', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _page(const [], supportedActions: ['maintenance', 'backup']),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();
      expect(find.text('Prepare isolated restore copy'), findsNothing);
      expect(
        find.byKey(const ValueKey('admin-restore-source-load')),
        findsNothing,
      );
      expect(harness.api.restoreSourceRequests, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('fine-grained local backup capabilities show their own panels', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _page(
        const [],
        supportedActions: [
          'maintenance',
          'backup',
          'backup_status',
          'backup_replication',
          'backup_schedule',
        ],
      ),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();
      expect(find.text('Instance backup status'), findsOneWidget);
      expect(find.text('Off-site encrypted backup copies'), findsOneWidget);
      expect(find.text('Scheduled encrypted backups'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('maintenance failure and interruption have readable results', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _page([
        _job(status: 'failed'),
        _job(
          status: 'interrupted',
          jobId: _jobId2,
          requestId: _backupRequestId,
        ),
      ]),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Maintenance failed; check server health'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Maintenance was interrupted; refresh the job list',
        ),
        findsOneWidget,
      );
      expect(find.text('Result maintenance_failed'), findsNothing);
      expect(find.text('Result interrupted'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('lost submission response retries with the same request ID', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.startErrors.add(
      const ApiException(
        statusCode: 503,
        code: 'TEMPORARILY_UNAVAILABLE',
        message: 'The service is temporarily unavailable.',
      ),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Run maintenance now'));
      await tester.tap(find.text('Run maintenance now'));
      await tester.pumpAndSettle();
      expect(find.text('Retry request safely'), findsOneWidget);
      final firstRequestId = harness.api.startRequests.single;

      harness.api.pages.add(_page([_job(status: 'succeeded')]));
      await tester.ensureVisible(find.text('Retry request safely'));
      await tester.tap(find.text('Retry request safely'));
      await tester.pumpAndSettle();
      expect(harness.api.startRequests, [firstRequestId, firstRequestId]);
      expect(find.text('Maintenance · succeeded'), findsOneWidget);
      expect(find.text('Retry request safely'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'admin can run encrypted backup and sees backup-specific result',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.backupListStatus = 'succeeded';
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Run encrypted backup'), findsOneWidget);
        expect(
          find.textContaining('ATERMIUS_BACKUP_ARCHIVE_DIR'),
          findsOneWidget,
        );
        expect(find.textContaining('ATERMIUS_BACKUP_KEY_FILE'), findsOneWidget);
        expect(
          find.textContaining(
            'No archive or key paths are sent by this client.',
          ),
          findsOneWidget,
        );

        await tester.ensureVisible(find.text('Run encrypted backup'));
        await tester.tap(find.text('Run encrypted backup'));
        await tester.pumpAndSettle();

        expect(harness.api.backupRequests, hasLength(1));
        expect(harness.api.backupActions, ['backup']);
        expect(harness.api.pageRequests, [(50, 0), (50, 0)]);
        expect(find.text('Encrypted backup · succeeded'), findsOneWidget);
        expect(
          find.textContaining('Encrypted backup completed on server'),
          findsOneWidget,
        );
        expect(find.text('Maintenance · succeeded'), findsNothing);
        expect(find.text('Encrypted backup job submitted. Its status appears in the list below.'), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('unconfigured backup retries with the same request ID safely', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(_page(const []));
    harness.api.backupListStatus = 'queued';
    harness.api.backupErrors.add(
      const ApiException(
        statusCode: 503,
        code: 'BACKUP_NOT_CONFIGURED',
        message: 'unsafe internal path /private/operator-backup.key',
      ),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Run encrypted backup'));
      await tester.tap(find.text('Run encrypted backup'));
      await tester.pumpAndSettle();
      expect(find.text('Retry backup request safely'), findsOneWidget);
      expect(
        find.textContaining('ATERMIUS_BACKUP_ARCHIVE_DIR'),
        findsNWidgets(2),
      );
      expect(find.textContaining('/private/operator-backup.key'), findsNothing);
      expect(find.textContaining('unsafe internal path'), findsNothing);
      final requestId = harness.api.backupRequests.single;

      await tester.ensureVisible(find.text('Retry backup request safely'));
      await tester.tap(find.text('Retry backup request safely'));
      await tester.pumpAndSettle();

      expect(harness.api.backupRequests, [requestId, requestId]);
      expect(harness.api.backupActions, ['backup', 'backup']);
      expect(find.text('Encrypted backup · queued'), findsOneWidget);
      expect(find.text('Retry backup request safely'), findsNothing);
      expect(find.textContaining('/private/operator-backup.key'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });
}

const _jobId2 = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Map<String, Object?> _jobJson({
  String status = 'succeeded',
  String jobId = _jobId,
  String requestId = _requestId,
  String action = 'maintenance',
}) => {
  'job_id': jobId,
  'request_id': requestId,
  'action': action,
  'status': status,
  'requested_at': '2026-09-29T10:00:00Z',
  'started_at': status == 'queued' ? null : '2026-09-29T10:00:01Z',
  'finished_at': switch (status) {
    'succeeded' || 'failed' || 'interrupted' => '2026-09-29T10:00:02Z',
    _ => null,
  },
  'result_code': switch (status) {
    'succeeded' => 'completed',
    'failed' => switch (action) {
      'backup' => 'backup_failed',
      'restore' => 'restore_failed',
      _ => 'maintenance_failed',
    },
    'interrupted' => 'interrupted',
    _ => null,
  },
  'archive_id': null,
  'archive_source': null,
  'restore_stage_status': null,
};

AdminMaintenanceJob _job({
  String status = 'succeeded',
  String jobId = _jobId,
  String requestId = _requestId,
  String action = 'maintenance',
}) => AdminMaintenanceJob.fromJson(
  _jobJson(status: status, jobId: jobId, requestId: requestId, action: action),
);

AdminMaintenanceJobsPage _page(
  List<AdminMaintenanceJob> jobs, {
  List<String> supportedActions = const [
    'maintenance',
    'backup',
    'restore',
    'backup_status',
    'backup_replication',
    'backup_schedule',
    'restore_replica',
    'restore_stage_discard',
  ],
}) => AdminMaintenanceJobsPage(
  jobs: jobs,
  total: jobs.length,
  limit: 50,
  offset: 0,
  supportedActions: supportedActions,
);

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
  final _WidgetAdminJobsApi api;
  final AppController app;

  static Future<_Harness> create(
    SodiumSumo sodium, {
    required bool isAdmin,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetAdminJobsApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
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

class _WidgetAdminJobsApi extends ApiClient {
  _WidgetAdminJobsApi()
    : super(
        baseUrl: 'https://admin-jobs-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final List<(int, int)> pageRequests = [];
  final List<String> startRequests = [];
  final List<String> backupRequests = [];
  final List<String> backupActions = [];
  final List<String> localBackupEndpointRequests = [];
  final List<int> restoreSourceRequests = [];
  InstanceAdminRestoreSourcesPage? restoreSources;
  final List<AdminMaintenanceJobsPage> pages = [];
  final List<ApiException> startErrors = [];
  final List<ApiException> backupErrors = [];
  String? backupListStatus;
  String? lastBackupRequestId;

  @override
  Future<AdminMaintenanceJobsPage> adminMaintenanceJobs({
    int limit = 50,
    int offset = 0,
  }) async {
    pageRequests.add((limit, offset));
    if (pages.isEmpty && backupListStatus != null) {
      return _page([
        _job(
          status: backupListStatus!,
          action: 'backup',
          jobId: _backupJobId,
          requestId: lastBackupRequestId ?? _backupRequestId,
        ),
      ]);
    }
    if (pages.isEmpty) throw StateError('No fake admin jobs page configured');
    return pages.removeAt(0);
  }

  @override
  Future<AdminMaintenanceJob> startAdminMaintenanceJob({
    required String requestId,
  }) async {
    startRequests.add(requestId);
    if (startErrors.isNotEmpty) throw startErrors.removeAt(0);
    return AdminMaintenanceJob.fromJson(
      _jobJson(status: 'queued', requestId: requestId),
    );
  }

  @override
  Future<AdminMaintenanceJob> startAdminBackupJob({
    required String requestId,
  }) async {
    backupRequests.add(requestId);
    backupActions.add('backup');
    lastBackupRequestId = requestId;
    if (backupErrors.isNotEmpty) throw backupErrors.removeAt(0);
    return AdminMaintenanceJob.fromJson(
      _jobJson(
        status: 'queued',
        action: 'backup',
        jobId: _backupJobId,
        requestId: requestId,
      ),
    );
  }

  @override
  Future<InstanceAdminBackupStatus> instanceAdminBackupStatus() async {
    localBackupEndpointRequests.add('backup-status');
    throw StateError('SQLite-only backup status endpoint was requested');
  }

  @override
  Future<InstanceAdminBackupReplicationStatus>
  instanceAdminBackupReplicationStatus() async {
    localBackupEndpointRequests.add('backup-replication');
    throw StateError('SQLite-only backup replication endpoint was requested');
  }

  @override
  Future<InstanceAdminBackupSchedule> instanceAdminBackupSchedule() async {
    localBackupEndpointRequests.add('backup-schedule');
    throw StateError('SQLite-only backup schedule endpoint was requested');
  }

  @override
  Future<InstanceAdminRestoreSourcesPage> instanceAdminRestoreSources({
    int limit = 50,
    int offset = 0,
  }) async {
    restoreSourceRequests.add(offset);
    final page = restoreSources;
    if (page == null) {
      throw StateError('No fake restore sources page configured');
    }
    return InstanceAdminRestoreSourcesPage(
      sources: page.sources,
      total: page.total,
      limit: limit,
      offset: offset,
    );
  }
}
