import 'support/settings_navigation.dart';

import 'dart:async';
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

const _archiveId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _jobId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _requestId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _discardRequestId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'restore source API is authenticated and uses bounded pagination',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://restore.example.test/prefix',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'sources': [_sourceJson()],
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
                action: 'restore',
                archiveId: body['archive_id']! as String,
                archiveSource: body['archive_source']! as String,
                requestId: body['request_id']! as String,
              ),
            }),
            202,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'admin-session-token';
      try {
        final page = await api.instanceAdminRestoreSources(
          limit: 25,
          offset: 50,
        );
        final job = await api.startAdminRestoreJob(
          requestId: _requestId,
          archiveId: _archiveId,
          archiveSource: 'replica',
        );
        expect(page.total, 1);
        expect(page.limit, 25);
        expect(page.offset, 50);
        expect(page.sources.single.origin, 'scheduled');
        expect(page.sources.single.source, 'local');
        expect(job.isRestore, isTrue);
        expect(job.archiveId, _archiveId);
        expect(job.archiveSource, 'replica');
        expect(requests.map((request) => request.method), ['GET', 'POST']);
        expect(requests[0].url.path, '/prefix/api/v1/admin/restore-sources');
        expect(requests[0].url.queryParameters, {
          'limit': '25',
          'offset': '50',
        });
        expect(
          requests[0].headers['authorization'],
          'Bearer admin-session-token',
        );
        expect(requests[1].url.path, '/prefix/api/v1/admin/jobs');
        expect(
          requests[1].headers['authorization'],
          'Bearer admin-session-token',
        );
        expect(jsonDecode(requests[1].body), {
          'request_id': _requestId,
          'action': 'restore',
          'archive_id': _archiveId,
          'archive_source': 'replica',
        });
      } finally {
        api.close();
      }
    },
  );

  test(
    'discard API is authenticated, path-bound, and validates its receipt',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://restore.example.test/prefix',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'restore_stage': {
                'restore_job_id': _jobId,
                'status': 'discarded',
                'discarded_at': '2026-10-01T09:31:02Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'admin-session-token';
      try {
        final result = await api.discardAdminRestoreStage(
          restoreJobId: _jobId,
          requestId: _discardRequestId,
        );
        expect(result.restoreJobId, _jobId);
        expect(result.discardedAt, DateTime.utc(2026, 10, 1, 9, 31, 2));
        expect(requests, hasLength(1));
        expect(
          requests.single.url.path,
          '/prefix/api/v1/admin/restore-stages/$_jobId/discard',
        );
        expect(
          requests.single.headers['authorization'],
          'Bearer admin-session-token',
        );
        expect(jsonDecode(requests.single.body), {
          'request_id': _discardRequestId,
        });
      } finally {
        api.close();
      }
    },
  );

  test(
    'discard API rejects invalid local identifiers without a request',
    () async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'https://restore.example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      try {
        await expectLater(
          api.discardAdminRestoreStage(
            restoreJobId: '/srv/live',
            requestId: _discardRequestId,
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.discardAdminRestoreStage(
            restoreJobId: _jobId,
            requestId: 'bad-request-id',
          ),
          throwsArgumentError,
        );
        expect(requests, 0);
      } finally {
        api.close();
      }
    },
  );

  test('discard API rejects unexpected response fields', () async {
    final api = ApiClient(
      baseUrl: 'https://restore.example.test',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'restore_stage': {
              'restore_job_id': _jobId,
              'status': 'discarded',
              'discarded_at': '2026-10-01T09:31:02Z',
            },
            'path': '/srv/restore-staging',
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    try {
      await expectLater(
        api.discardAdminRestoreStage(
          restoreJobId: _jobId,
          requestId: _discardRequestId,
        ),
        throwsFormatException,
      );
    } finally {
      api.close();
    }
  });

  test(
    'restore API rejects invalid local inputs without sending requests',
    () async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'https://restore.example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      try {
        await expectLater(
          api.instanceAdminRestoreSources(limit: 101),
          throwsArgumentError,
        );
        await expectLater(
          api.instanceAdminRestoreSources(offset: 1000001),
          throwsArgumentError,
        );
        await expectLater(
          api.startAdminRestoreJob(
            requestId: _requestId,
            archiveId: '/tmp/a',
            archiveSource: 'local',
          ),
          throwsArgumentError,
        );
        expect(requests, 0);
      } finally {
        api.close();
      }
    },
  );

  test('restore source and job DTOs reject unsafe or inconsistent data', () {
    final page = InstanceAdminRestoreSourcesPage.fromJson(
      {
        'sources': [_sourceJson()],
        'total': 1,
      },
      limit: 50,
      offset: 0,
    );
    expect(page.sources.single.archiveId, _archiveId);
    expect(page.sources.single.archiveBytes, 4096);
    expect(page.sources.single.source, 'local');
    final localAndReplica = InstanceAdminRestoreSourcesPage.fromJson(
      {
        'sources': [
          _sourceJson(source: 'local'),
          _sourceJson(source: 'replica'),
        ],
        'total': 2,
      },
      limit: 50,
      offset: 0,
    );
    expect(localAndReplica.sources.map((source) => source.source), [
      'local',
      'replica',
    ]);
    expect(
      () => InstanceAdminRestoreSource.fromJson({
        ..._sourceJson(),
        'archive_id': _archiveId.toUpperCase(),
      }),
      throwsFormatException,
    );
    for (final bad in [
      {..._sourceJson(), 'created_at': 'yesterday'},
      {..._sourceJson(), 'archive_bytes': 0},
      {..._sourceJson(), 'origin': 'operator-path'},
      {..._sourceJson(), 'archive_path': '/srv/secret.atb'},
      {..._sourceJson(), 'source': 'operator-path'},
    ]) {
      expect(
        () => InstanceAdminRestoreSource.fromJson(bad),
        throwsFormatException,
      );
    }
    expect(
      AdminMaintenanceJob.fromJson(
        _jobJson(status: 'queued', action: 'restore', archiveId: _archiveId),
      ).archiveSource,
      'local',
    );
    expect(
      AdminMaintenanceJob.fromJson(
        _jobJson(status: 'queued', action: 'restore', archiveId: _archiveId),
      ).archiveId,
      _archiveId,
    );
    expect(
      AdminMaintenanceJob.fromJson(
        _jobJson(
          status: 'failed',
          action: 'restore',
          resultCode: 'restore_failed',
          archiveId: _archiveId,
        ),
      ).resultCode,
      'restore_failed',
    );
    final legacySucceededRestore = AdminMaintenanceJob.fromJson({
      ..._jobJson(
        status: 'succeeded',
        action: 'restore',
        archiveId: _archiveId,
      ),
      'restore_stage_status': null,
    });
    expect(legacySucceededRestore.restoreStageStatus, isNull);
    final interruptedAfterPublish = AdminMaintenanceJob.fromJson({
      ..._jobJson(
        status: 'interrupted',
        action: 'restore',
        archiveId: _archiveId,
      ),
      'restore_stage_status': 'ready',
    });
    expect(interruptedAfterPublish.restoreStageStatus, 'ready');
    for (final bad in [
      {..._jobJson(status: 'queued', action: 'restore'), 'archive_id': null},
      {
        ..._jobJson(status: 'queued', action: 'restore'),
        'archive_source': 'operator-path',
      },
      {
        ..._jobJson(
          status: 'succeeded',
          action: 'restore',
          archiveId: _archiveId,
        ),
        'result_code': 'backup_failed',
      },
      {..._jobJson(), 'archive_id': _archiveId},
      {..._jobJson(), 'restore_stage_status': 'unverified'},
      {
        ..._jobJson(status: 'queued', action: 'restore', archiveId: _archiveId),
        'restore_stage_status': 'discarding',
      },
      {..._jobJson(), 'restore_target': '/srv/live-data'},
    ]) {
      expect(() => AdminMaintenanceJob.fromJson(bad), throwsFormatException);
    }
  });

  testWidgets('restore controls and source loads are hidden for members', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Prepare isolated restore copy'), findsNothing);
      expect(
        find.byKey(const ValueKey('admin-restore-source-load')),
        findsNothing,
      );
      expect(harness.api.sourceRequests, isEmpty);
      expect(harness.api.restoreRequests, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'stage status is visible but discard needs its own advertised capability',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final ready = _job(
        status: 'succeeded',
        action: 'restore',
        archiveId: _archiveId,
      );
      harness.api.jobListPages.add(
        _jobsPage(
          [ready],
          supportedActions: const ['maintenance', 'backup', 'restore'],
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Restore staging · Prepared'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('admin-restore-stage-discard-$_jobId')),
          findsNothing,
        );
        expect(await harness.app.discardAdminRestoreStage(_jobId), isFalse);
        expect(harness.api.discardRequests, isEmpty);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'discard needs confirmation and safely retries with the same request ID',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final ready = _job(
        status: 'succeeded',
        action: 'restore',
        archiveId: _archiveId,
      );
      final discarded = ready.withRestoreStageStatus('discarded');
      harness.api.jobListPages.addAll([
        _jobsPage([ready]),
        _jobsPage([discarded]),
      ]);
      harness.api.discardErrors.add(
        const ApiException(
          statusCode: 500,
          code: 'RESTORE_STAGE_DISCARD_FAILED',
          message: 'internal /srv/restore-staging and secret-key',
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        final discard = find.byKey(
          const ValueKey('admin-restore-stage-discard-$_jobId'),
        );
        await tester.ensureVisible(discard);
        await tester.tap(discard);
        await tester.pumpAndSettle();
        expect(find.text('Discard isolated restore copy?'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('admin-restore-stage-discard-cancel')),
        );
        await tester.pumpAndSettle();
        expect(harness.api.discardRequests, isEmpty);

        await tester.ensureVisible(discard);
        await tester.tap(discard);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('admin-restore-stage-discard-confirm')),
        );
        await tester.pumpAndSettle();
        expect(harness.api.discardRequests, hasLength(1));
        expect(
          harness.app.adminRestoreStageDiscardError,
          isNot(contains('/srv')),
        );
        expect(
          harness.app.adminRestoreStageDiscardError,
          isNot(contains('secret-key')),
        );
        expect(harness.app.canRetryAdminRestoreStageDiscardFor(_jobId), isTrue);
        final requestId = harness.api.discardRequests.single.requestId;
        expect(requestId, matches(_uuidPattern));

        final retry = find.byKey(
          const ValueKey('admin-restore-stage-discard-retry'),
        );
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(harness.api.discardRequests, hasLength(2));
        expect(harness.api.discardRequests.last.requestId, requestId);
        expect(
          harness.app.adminMaintenanceJobsPage?.jobs.single.restoreStageStatus,
          'discarded',
        );
        expect(find.text("The isolated restore copy was discarded. The source archive and live data weren't changed."), findsOneWidget);
        expect(find.textContaining('/srv/'), findsNothing);
        expect(find.textContaining('secret-key'), findsNothing);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'cancel sends no request; confirm submits once and shows safe stage',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.sources = _sourcePage();
      harness.api.jobListPages.add(_jobsPage(const []));
      harness.api.pollPages.add(
        _jobsPage(
          [_job(status: 'succeeded', action: 'restore', archiveId: _archiveId)],
          supportedActions: const ['maintenance', 'backup'],
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-restore-source-load')),
        );
        await tester.tap(
          find.byKey(const ValueKey('admin-restore-source-load')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Scheduled ·'), findsOneWidget);
        await tester.tap(
          find.byKey(
            const ValueKey('admin-restore-source-option-local-$_archiveId'),
          ),
        );
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-restore-submit')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-restore-submit')));
        await tester.pumpAndSettle();
        expect(find.text('Prepare isolated restore copy?'), findsOneWidget);
        expect(
          find.textContaining(
            'does not change active account, Vault, session, or generation data',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('admin-restore-cancel')));
        await tester.pumpAndSettle();
        expect(harness.api.restoreRequests, isEmpty);

        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-restore-submit')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-restore-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('admin-restore-confirm')));
        await tester.pumpAndSettle();
        expect(harness.api.restoreRequests, hasLength(1));
        expect(harness.api.restoreRequests.single.archiveId, _archiveId);
        expect(
          harness.api.restoreRequests.single.requestId,
          matches(_uuidPattern),
        );
        expect(find.text('Restore staging · Prepared'), findsOneWidget);
        expect(find.text('Stage ID'), findsOneWidget);
        expect(find.text(_jobId), findsOneWidget);
        expect(
          find.textContaining('not currently accepting restore requests'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('admin-restore-source-load')),
          findsNothing,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('admin-restore-submit')),
              )
              .onPressed,
          isNull,
        );
        expect(find.textContaining('/srv/'), findsNothing);
        expect(find.textContaining('secret-key'), findsNothing);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('remote replica selection is bound to restore job source', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.sources = InstanceAdminRestoreSourcesPage.fromJson(
      {
        'sources': [
          _sourceJson(source: 'local'),
          _sourceJson(source: 'replica'),
        ],
        'total': 2,
      },
      limit: 50,
      offset: 0,
    );
    harness.api.jobListPages.add(_jobsPage(const []));
    harness.api.pollPages.add(
      _jobsPage([
        _job(
          status: 'succeeded',
          action: 'restore',
          archiveId: _archiveId,
          archiveSource: 'replica',
        ),
      ]),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-restore-source-load')),
      );
      await tester.tap(find.byKey(const ValueKey('admin-restore-source-load')));
      await tester.pumpAndSettle();
      final remoteOption = find.byKey(
        const ValueKey('admin-restore-source-option-replica-$_archiveId'),
      );
      expect(remoteOption, findsOneWidget);
      await tester.ensureVisible(remoteOption);
      await tester.tap(remoteOption);
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-restore-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('admin-restore-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-restore-confirm')));
      await tester.pumpAndSettle();

      expect(harness.api.restoreRequests, hasLength(1));
      expect(harness.api.restoreRequests.single.archiveId, _archiveId);
      expect(harness.api.restoreRequests.single.archiveSource, 'replica');
      expect(harness.app.adminRestoreJob?.archiveSource, 'replica');
      expect(find.text('Restore staging · Prepared'), findsOneWidget);
    } finally {
      await _disposeHarness(harness);
    }
  });

  test('retry after uncertain response reuses the same request ID', () async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.restoreErrors.add(
      const ApiException(
        statusCode: 503,
        code: 'TEMPORARILY_UNAVAILABLE',
        message: 'internal /srv/live database path and secret-key',
      ),
    );
    harness.api.pollPages.add(
      _jobsPage([
        _job(status: 'succeeded', action: 'restore', archiveId: _archiveId),
      ]),
    );
    try {
      expect(
        await harness.app.startAdminRestoreStage(archiveId: _archiveId),
        isFalse,
      );
      expect(harness.app.canRetryAdminRestoreSubmission, isTrue);
      expect(harness.app.adminRestoreError, isNot(contains('/srv')));
      expect(harness.app.adminRestoreError, isNot(contains('secret-key')));
      expect(
        await harness.app.startAdminRestoreStage(archiveId: _archiveId),
        isTrue,
      );
      expect(harness.api.restoreRequests, hasLength(2));
      expect(
        harness.api.restoreRequests[0].requestId,
        harness.api.restoreRequests[1].requestId,
      );
      expect(harness.app.adminRestoreJob?.status, 'succeeded');
      expect(harness.app.adminRestorePolling, isFalse);
    } finally {
      await _disposeHarness(harness);
    }
  });

  testWidgets('restore polling is bounded for a job that stays active', (
    tester,
  ) async {
    final harness = await _Harness.create(
      sodium,
      isAdmin: true,
      pollInterval: const Duration(seconds: 1),
      pollMaxAttempts: 2,
    );
    final activePage = _jobsPage([
      _job(status: 'queued', action: 'restore', archiveId: _archiveId),
    ]);
    harness.api.pollPages.addAll([activePage, activePage, activePage]);
    try {
      expect(
        await harness.app.startAdminRestoreStage(archiveId: _archiveId),
        isTrue,
      );
      expect(harness.app.adminRestorePolling, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(harness.app.adminRestorePolling, isFalse);
      expect(harness.api.pollRequests, hasLength(2));
      expect(harness.app.adminRestoreNotice, contains('automatic status checks are paused'));
      await tester.pump(const Duration(seconds: 5));
      expect(harness.api.pollRequests, hasLength(2));
    } finally {
      await _disposeHarness(harness);
    }
  });

  testWidgets(
    'late active jobs page cannot roll a prepared restore stage back',
    (tester) async {
      final harness = await _Harness.create(
        sodium,
        isAdmin: true,
        pollInterval: const Duration(hours: 1),
      );
      harness.app.adminMaintenanceJobsPage = _jobsPage(const []);
      final staleJobsResponse = Completer<AdminMaintenanceJobsPage>();
      harness.api.nextJobListPage = staleJobsResponse.future;
      final staleLoad = harness.app.loadAdminMaintenanceJobs(offset: 0);
      harness.api.pollPageFactories.add(
        () => _jobsPage([
          _job(
            status: 'succeeded',
            action: 'restore',
            archiveId: _archiveId,
            requestId: harness.api.restoreRequests.single.requestId,
          ),
        ]),
      );
      try {
        expect(
          await harness.app.startAdminRestoreStage(archiveId: _archiveId),
          isTrue,
        );
        expect(harness.app.adminRestoreJob?.status, 'succeeded');
        expect(harness.app.adminRestoreJob?.restoreStageStatus, 'ready');
        expect(harness.app.adminRestorePolling, isFalse);

        staleJobsResponse.complete(
          _jobsPage([
            _job(
              status: 'queued',
              action: 'restore',
              archiveId: _archiveId,
              requestId: harness.api.restoreRequests.single.requestId,
            ),
          ]),
        );
        await staleLoad;

        expect(harness.app.adminRestoreJob?.status, 'succeeded');
        expect(harness.app.adminRestoreJob?.restoreStageStatus, 'ready');
        expect(
          harness.app.adminMaintenanceJobsPage?.jobs.single.status,
          'succeeded',
        );
        expect(harness.app.adminRestorePolling, isFalse);
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Restore staging · Prepared'), findsOneWidget);
        expect(find.text('Stage ID'), findsOneWidget);
        expect(find.text(_jobId), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('logout stops polling and clears staged restore state', (
    tester,
  ) async {
    final harness = await _Harness.create(
      sodium,
      isAdmin: true,
      pollInterval: const Duration(seconds: 1),
      pollMaxAttempts: 10,
    );
    harness.api.pollPages.add(
      _jobsPage([
        _job(status: 'queued', action: 'restore', archiveId: _archiveId),
      ]),
    );
    try {
      expect(
        await harness.app.startAdminRestoreStage(archiveId: _archiveId),
        isTrue,
      );
      expect(harness.api.pollRequests, hasLength(1));
      expect(harness.app.adminRestorePolling, isTrue);
      await harness.app.logout();
      expect(harness.app.adminRestoreJob, isNull);
      expect(harness.app.adminRestorePolling, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(harness.api.pollRequests, hasLength(1));
    } finally {
      await _disposeHarness(harness);
    }
  });

  testWidgets('disposing the controller stops restore polling', (tester) async {
    final harness = await _Harness.create(
      sodium,
      isAdmin: true,
      pollInterval: const Duration(seconds: 1),
      pollMaxAttempts: 10,
    );
    harness.api.pollPages.add(
      _jobsPage([
        _job(status: 'queued', action: 'restore', archiveId: _archiveId),
      ]),
    );
    try {
      expect(
        await harness.app.startAdminRestoreStage(archiveId: _archiveId),
        isTrue,
      );
      expect(harness.api.pollRequests, hasLength(1));
      harness.app.dispose();
      await tester.pump(const Duration(seconds: 3));
      expect(harness.api.pollRequests, hasLength(1));
    } finally {
      harness.api.close();
      await harness.database.close();
    }
  });

  test(
    'loading page zero after a reload rehydrates and resumes a restore job',
    () async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final activeJob = _job(
        status: 'running',
        action: 'restore',
        archiveId: _archiveId,
        jobId: _jobId,
      );
      harness.api.jobListPages.add(_jobsPage([activeJob]));
      harness.api.pollPages.add(_jobsPage([activeJob]));
      try {
        expect(harness.app.adminRestoreJob, isNull);
        await harness.app.loadAdminMaintenanceJobs(offset: 0);
        expect(harness.app.adminRestoreJob?.jobId, _jobId);
        expect(harness.app.adminRestoreJob?.status, 'running');
        expect(harness.app.adminRestorePolling, isTrue);
        expect(harness.api.jobListRequests, [(50, 0)]);
        expect(harness.api.pollRequests, [(50, 0)]);
      } finally {
        await _disposeHarness(harness);
      }
    },
  );

  testWidgets(
    'Settings reload recovers the durable active stage automatically',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final activeJob = _job(
        status: 'running',
        action: 'restore',
        archiveId: _archiveId,
        jobId: _jobId,
      );
      harness.api.jobListPages.add(_jobsPage([activeJob]));
      harness.api.pollPages.add(_jobsPage([activeJob]));
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.text('Restore staging · Preparing isolated copy'),
          findsOneWidget,
        );
        expect(find.text(_jobId), findsOneWidget);
        expect(harness.app.adminRestorePolling, isTrue);
        expect(harness.api.jobListRequests, [(50, 0)]);
        expect(harness.api.pollRequests, [(50, 0)]);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'legacy successful restore without a verified stage stays non-actionable',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final legacyJob = _job(
        status: 'succeeded',
        action: 'restore',
        archiveId: _archiveId,
      ).withRestoreStageStatus(null);
      harness.api.jobListPages.add(_jobsPage([legacyJob]));
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Restore staging · Unverified'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('admin-restore-stage-discard-$_jobId')),
          findsNothing,
        );
        expect(harness.app.adminRestoreNotice, contains('The restore job finished, but the isolated copy state isn\'t verified and can\'t be managed from here.'));
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('owner can safely retry an unverified completed restore copy', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    final unverified = _job(
      status: 'succeeded',
      action: 'restore',
      archiveId: _archiveId,
    ).withRestoreStageStatus('unverified');
    harness.api.jobListPages.addAll([
      _jobsPage([unverified]),
      _jobsPage([unverified.withRestoreStageStatus('discarded')]),
    ]);
    try {
      await _pumpSettings(tester, harness.app);
      await tester.pumpAndSettle();
      expect(find.text('Restore staging · Unverified'), findsOneWidget);
      final discard = find.byKey(
        const ValueKey('admin-restore-stage-discard-$_jobId'),
      );
      expect(discard, findsOneWidget);
      expect(find.byTooltip('Verify and discard'), findsOneWidget);
      await tester.ensureVisible(discard);
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('server first validates that this copy'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-restore-stage-discard-confirm')),
      );
      await tester.pumpAndSettle();
      expect(harness.api.discardRequests, hasLength(1));
      expect(
        harness.app.adminMaintenanceJobsPage?.jobs.single.restoreStageStatus,
        'discarded',
      );
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'owner can resume a discard left pending across a server restart',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final discarding = _job(
        status: 'succeeded',
        action: 'restore',
        archiveId: _archiveId,
      ).withRestoreStageStatus('discarding');
      harness.api.jobListPages.addAll([
        _jobsPage([discarding]),
        _jobsPage([discarding.withRestoreStageStatus('discarded')]),
      ]);
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Restore staging · Cleanup pending'), findsOneWidget);
        final retry = find.byKey(
          const ValueKey('admin-restore-stage-discard-$_jobId'),
        );
        expect(retry, findsOneWidget);
        expect(find.byTooltip('Retry discard'), findsOneWidget);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('admin-restore-stage-discard-confirm')),
        );
        await tester.pumpAndSettle();
        expect(harness.api.discardRequests, hasLength(1));
        expect(
          harness.app.adminMaintenanceJobsPage?.jobs.single.restoreStageStatus,
          'discarded',
        );
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'owner can discard a durably published stage after job finalization was interrupted',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final interrupted = AdminMaintenanceJob.fromJson({
        ..._jobJson(
          status: 'interrupted',
          action: 'restore',
          archiveId: _archiveId,
        ),
        'restore_stage_status': 'ready',
      });
      harness.api.jobListPages.add(_jobsPage([interrupted]));
      try {
        await _pumpSettings(tester, harness.app);
        await tester.pumpAndSettle();
        expect(find.text('Restore staging · Prepared'), findsOneWidget);
        final discard = find.byKey(
          const ValueKey('admin-restore-stage-discard-$_jobId'),
        );
        expect(discard, findsOneWidget);
        await tester.ensureVisible(discard);
        await tester.tap(discard);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('admin-restore-stage-discard-confirm')),
        );
        await tester.pumpAndSettle();
        expect(harness.api.discardRequests, hasLength(1));
        expect(
          harness.app.adminMaintenanceJobsPage?.jobs.single.status,
          'interrupted',
        );
        expect(
          harness.app.adminMaintenanceJobsPage?.jobs.single.restoreStageStatus,
          'discarded',
        );
      } finally {
        await _dispose(tester, harness);
      }
    },
  );
}

const _uuidPattern =
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

Map<String, Object?> _sourceJson({
  String archiveId = _archiveId,
  int archiveBytes = 4096,
  String origin = 'scheduled',
  String source = 'local',
}) => {
  'archive_id': archiveId,
  'created_at': '2026-10-01T09:30:00Z',
  'archive_bytes': archiveBytes,
  'origin': origin,
  'source': source,
};

Map<String, Object?> _jobJson({
  String status = 'succeeded',
  String action = 'maintenance',
  String jobId = _jobId,
  String requestId = _requestId,
  String? archiveId,
  String? archiveSource,
  String? resultCode,
}) => {
  'job_id': jobId,
  'request_id': requestId,
  'action': action,
  'status': status,
  'requested_at': '2026-10-01T09:31:00Z',
  'started_at': status == 'queued' ? null : '2026-10-01T09:31:01Z',
  'finished_at': switch (status) {
    'succeeded' || 'failed' || 'interrupted' => '2026-10-01T09:31:02Z',
    _ => null,
  },
  'result_code':
      resultCode ??
      switch (status) {
        'succeeded' => 'completed',
        'failed' => switch (action) {
          'backup' => 'backup_failed',
          'restore' => 'restore_failed',
          _ => 'maintenance_failed',
        },
        'interrupted' => 'interrupted',
        _ => null,
      },
  'archive_id': archiveId,
  'archive_source': archiveSource ?? (action == 'restore' ? 'local' : null),
  'restore_stage_status': action == 'restore' && status == 'succeeded'
      ? 'ready'
      : null,
};

AdminMaintenanceJob _job({
  String status = 'succeeded',
  String action = 'maintenance',
  String? archiveId,
  String archiveSource = 'local',
  String jobId = _jobId,
  String requestId = _requestId,
}) => AdminMaintenanceJob.fromJson(
  _jobJson(
    status: status,
    action: action,
    archiveId: archiveId,
    archiveSource: action == 'restore' ? archiveSource : null,
    jobId: jobId,
    requestId: requestId,
  ),
);

InstanceAdminRestoreSourcesPage _sourcePage() =>
    InstanceAdminRestoreSourcesPage.fromJson(
      {
        'sources': [_sourceJson()],
        'total': 1,
      },
      limit: 50,
      offset: 0,
    );

AdminMaintenanceJobsPage _jobsPage(
  List<AdminMaintenanceJob> jobs, {
  List<String> supportedActions = const [
    'maintenance',
    'backup',
    'restore',
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
  await _disposeHarness(harness);
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _disposeHarness(_Harness harness) async {
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _TestApi api;
  final AppController app;

  static Future<_Harness> create(
    SodiumSumo sodium, {
    required bool isAdmin,
    Duration pollInterval = const Duration(hours: 1),
    int pollMaxAttempts = 120,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _TestApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            adminRestorePollIntervalForTesting: pollInterval,
            adminRestorePollMaxAttemptsForTesting: pollMaxAttempts,
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

class _TestApi extends ApiClient {
  _TestApi()
    : super(
        baseUrl: 'https://admin-restore-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  InstanceAdminRestoreSourcesPage? sources;
  final List<int> sourceRequests = [];
  final List<({String requestId, String archiveId, String archiveSource})>
  restoreRequests = [];
  final List<ApiException> restoreErrors = [];
  final List<({String restoreJobId, String requestId})> discardRequests = [];
  final List<ApiException> discardErrors = [];
  final List<AdminMaintenanceJobsPage> jobListPages = [];
  final List<(int, int)> jobListRequests = [];
  Future<AdminMaintenanceJobsPage>? nextJobListPage;
  final List<AdminMaintenanceJobsPage> pollPages = [];
  final List<AdminMaintenanceJobsPage Function()> pollPageFactories = [];
  final List<(int, int)> pollRequests = [];

  @override
  Future<InstanceAdminRestoreSourcesPage> instanceAdminRestoreSources({
    int limit = 50,
    int offset = 0,
  }) async {
    sourceRequests.add(offset);
    final page = sources;
    if (page == null) throw StateError('No fake restore sources configured');
    return InstanceAdminRestoreSourcesPage(
      sources: page.sources,
      total: page.total,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<AdminMaintenanceJob> startAdminRestoreJob({
    required String requestId,
    required String archiveId,
    required String archiveSource,
  }) async {
    restoreRequests.add((
      requestId: requestId,
      archiveId: archiveId,
      archiveSource: archiveSource,
    ));
    if (restoreErrors.isNotEmpty) throw restoreErrors.removeAt(0);
    return AdminMaintenanceJob.fromJson(
      _jobJson(
        status: 'queued',
        action: 'restore',
        archiveId: archiveId,
        archiveSource: archiveSource,
        requestId: requestId,
      ),
    );
  }

  @override
  Future<AdminMaintenanceJobsPage> adminMaintenanceJobs({
    int limit = 50,
    int offset = 0,
  }) async {
    if (jobListPages.isNotEmpty) {
      jobListRequests.add((limit, offset));
      return jobListPages.removeAt(0);
    }
    final pendingJobListPage = nextJobListPage;
    if (pendingJobListPage != null) {
      nextJobListPage = null;
      jobListRequests.add((limit, offset));
      return pendingJobListPage;
    }
    pollRequests.add((limit, offset));
    if (pollPageFactories.isNotEmpty) {
      return pollPageFactories.removeAt(0)();
    }
    if (pollPages.isEmpty) {
      throw StateError('No fake restore status configured');
    }
    return pollPages.removeAt(0);
  }

  @override
  Future<InstanceAdminRestoreStageDiscard> discardAdminRestoreStage({
    required String restoreJobId,
    required String requestId,
  }) async {
    discardRequests.add((restoreJobId: restoreJobId, requestId: requestId));
    if (discardErrors.isNotEmpty) throw discardErrors.removeAt(0);
    return InstanceAdminRestoreStageDiscard(
      restoreJobId: restoreJobId,
      discardedAt: DateTime.utc(2026, 10, 1, 9, 31, 2),
    );
  }

  @override
  Future<void> logout() async {}
}
