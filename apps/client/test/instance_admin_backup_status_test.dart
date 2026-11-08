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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backup status API uses the authenticated read-only endpoint', () async {
    late http.Request captured;
    final api = ApiClient(
      baseUrl: 'https://admin.example.test/prefix',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_successStatus),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      final status = await api.instanceAdminBackupStatus();
      expect(captured.method, 'GET');
      expect(captured.url.path, '/prefix/api/v1/admin/backup-status');
      expect(captured.headers['authorization'], 'Bearer session-access-token');
      expect(status.lastAttempt?.result, 'succeeded');
      expect(status.lastAttempt?.migrationVersion, 23);
      expect(status.lastAttempt?.archiveBytes, 4096);
      expect(status.lastAttempt?.attemptedAt, DateTime.utc(2026, 9, 30, 12));
    } finally {
      api.close();
    }
  });

  test('backup status parser accepts absence and fixed outcomes only', () {
    expect(
      InstanceAdminBackupStatus.fromJson({
        'operation': 'backup',
        'last_attempt': null,
      }).lastAttempt,
      isNull,
    );
    expect(
      InstanceAdminBackupStatus.fromJson(_successStatus).lastAttempt?.result,
      'succeeded',
    );
    final successWithoutVisibleArchive =
        jsonDecode(jsonEncode(_successStatus)) as Map<String, dynamic>;
    (successWithoutVisibleArchive['last_attempt']
            as Map<String, dynamic>)['archive_bytes'] =
        null;
    expect(
      InstanceAdminBackupStatus.fromJson(successWithoutVisibleArchive)
          .lastAttempt
          ?.archiveBytes,
      isNull,
    );
    expect(
      InstanceAdminBackupStatus.fromJson(_failureStatus)
          .lastAttempt
          ?.failureCategory,
      'backup_failed',
    );

    final arbitraryFailure = jsonDecode(jsonEncode(_failureStatus)) as Map;
    (arbitraryFailure['last_attempt'] as Map)['failure_category'] =
        'secret path: /private/archive.atb';
    expect(
      () => InstanceAdminBackupStatus.fromJson(
        Map<String, dynamic>.from(arbitraryFailure),
      ),
      throwsFormatException,
    );
    expect(
      () => InstanceAdminBackupStatus.fromJson({'operation': 'verify-backup'}),
      throwsFormatException,
    );
    expect(
      () => InstanceAdminBackupStatus.fromJson({
        'operation': 'backup',
        'last_attempt': null,
        'archive_path': '/private/archive.atb',
      }),
      throwsFormatException,
    );

    final zeroMigrationStatus =
        jsonDecode(jsonEncode(_successStatus)) as Map<String, dynamic>;
    final zeroMigrationAttempt =
        zeroMigrationStatus['last_attempt'] as Map<String, dynamic>;
    zeroMigrationAttempt['migration_version'] = 0;
    expect(
      InstanceAdminBackupStatus.fromJson(zeroMigrationStatus)
          .lastAttempt
          ?.migrationVersion,
      0,
    );

    final zeroLengthStatus = jsonDecode(jsonEncode(_successStatus)) as Map;
    (zeroLengthStatus['last_attempt'] as Map)['archive_bytes'] = 0;
    expect(
      () => InstanceAdminBackupStatus.fromJson(
        Map<String, dynamic>.from(zeroLengthStatus),
      ),
      throwsFormatException,
    );
  });

  test(
    'backup replication API uses its authenticated fixed endpoint',
    () async {
      late http.Request captured;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_replicationSucceeded),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final status = await api.instanceAdminBackupReplicationStatus();
        expect(captured.method, 'GET');
        expect(captured.url.path, '/prefix/api/v1/admin/backup-replication');
        expect(
          captured.headers['authorization'],
          'Bearer session-access-token',
        );
        expect(status.configured, isTrue);
        expect(status.pendingCount, 0);
        expect(status.latestAttempt?.state, 'succeeded');
        expect(status.latestAttempt?.archiveBytes, 4096);
      } finally {
        api.close();
      }
    },
  );

  test('bucket access preflight sends only fixed empty JSON', () async {
    late http.Request captured;
    final api = ApiClient(
      baseUrl: 'https://admin.example.test/prefix',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'check': 'bucket_access', 'result': 'passed'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      await api.instanceAdminBackupBucketAccessCheck();
      expect(captured.method, 'POST');
      expect(
        captured.url.path,
        '/prefix/api/v1/admin/backup-replication/preflight',
      );
      expect(captured.url.hasQuery, isFalse);
      expect(captured.body, '{}');
      expect(
        captured.headers['content-type'],
        'application/json; charset=utf-8',
      );
      expect(captured.headers['authorization'], 'Bearer session-access-token');
    } finally {
      api.close();
    }
  });

  test('bucket access preflight accepts only the fixed safe result DTO', () {
    expect(
      InstanceAdminBackupBucketAccessCheck.fromJson({
        'check': 'bucket_access',
        'result': 'passed',
      }),
      isA<InstanceAdminBackupBucketAccessCheck>(),
    );
    for (final bad in [
      {'check': 'bucket_access', 'result': 'failed'},
      {
        'check': 'bucket_access',
        'result': 'passed',
        'provider_error': 'private endpoint and credentials',
      },
      {
        'check': 'bucket_access',
        'result': 'passed',
        'bucket': 'private-backup-bucket',
      },
    ]) {
      expect(
        () => InstanceAdminBackupBucketAccessCheck.fromJson(bad),
        throwsFormatException,
      );
    }
  });

  test(
    'backup replication DTO rejects destination data and invalid outcomes',
    () {
      final status = InstanceAdminBackupReplicationStatus.fromJson(
        _replicationSucceeded,
      );
      expect(status.latestAttempt?.failureCategory, isNull);
      expect(
        InstanceAdminBackupReplicationStatus.fromJson({
          'operation': 'backup_replication',
          'configured': false,
          'pending_count': 0,
          'latest_attempt': null,
        }).latestAttempt,
        isNull,
      );

      final remoteFailure =
          jsonDecode(jsonEncode(_replicationSucceeded)) as Map<String, dynamic>;
      final attempt = remoteFailure['latest_attempt'] as Map<String, dynamic>;
      attempt['state'] = 'failed';
      attempt['completed_at'] = '2026-10-04T12:01:00Z';
      attempt['failure_category'] = 'remote_unavailable';
      attempt['archive_bytes'] = null;
      expect(
        InstanceAdminBackupReplicationStatus.fromJson(remoteFailure)
            .latestAttempt
            ?.failureCategory,
        'remote_unavailable',
      );

      for (final bad in [
        {..._replicationSucceeded, 'bucket': 'private-backup-bucket'},
        {..._replicationSucceeded, 'pending_count': -1},
        {
          ..._replicationSucceeded,
          'latest_attempt': {
            ...(_replicationSucceeded['latest_attempt']!
                as Map<String, dynamic>),
            'failure_category': 'https://secret.endpoint.invalid',
          },
        },
        {
          ..._replicationSucceeded,
          'latest_attempt': {
            ...(_replicationSucceeded['latest_attempt']!
                as Map<String, dynamic>),
            'object_key': 'backups/private.atb',
          },
        },
      ]) {
        expect(
          () => InstanceAdminBackupReplicationStatus.fromJson(bad),
          throwsFormatException,
        );
      }
    },
  );

  testWidgets('backup status card is hidden for non-admin accounts', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance backup status'), findsNothing);
      expect(find.text('Load backup status'), findsNothing);
      expect(find.text('Off-site encrypted backup copies'), findsNothing);
      expect(
        find.byKey(const ValueKey('admin-backup-replication-preflight')),
        findsNothing,
      );
      expect(harness.api.calls, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('allowlisted admin sees fixed backup result and its limits', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    final pending = Completer<InstanceAdminBackupStatus>();
    harness.api.response = pending.future;
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance backup status'), findsOneWidget);
      await tester.ensureVisible(find.text('Load backup status'));
      await tester.tap(find.text('Load backup status'));
      await tester.pump();
      expect(find.text('Reading the latest backup command status…'), findsOneWidget);

      pending.complete(InstanceAdminBackupStatus.fromJson(_successStatus));
      await tester.pumpAndSettle();
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.text('Migration version'), findsOneWidget);
      expect(find.text('23'), findsOneWidget);
      expect(find.text('Archive bytes'), findsOneWidget);
      expect(find.textContaining('4.0 KiB (4,096 bytes)'), findsOneWidget);
      expect(
        find.textContaining('does not confirm that the archive still exists'),
        findsOneWidget,
      );
      expect(find.text('Refresh backup status'), findsOneWidget);
      expect(harness.api.calls, 1);
    } finally {
      if (!pending.isCompleted) pending.completeError(StateError('disposed'));
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin sees when a successful archive size is unavailable', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    final unavailableSize = jsonDecode(jsonEncode(_successStatus)) as Map;
    (unavailableSize['last_attempt'] as Map)['archive_bytes'] = null;
    harness.api.response = Future.value(
      InstanceAdminBackupStatus.fromJson(
        Map<String, dynamic>.from(unavailableSize),
      ),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup status'));
      await tester.tap(find.text('Load backup status'));
      await tester.pumpAndSettle();
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.text('Archive bytes'), findsOneWidget);
      expect(find.text('Unavailable on this node'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin sees safe durable off-site copy status', (tester) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.replicationResponse =
        InstanceAdminBackupReplicationStatus.fromJson(_replicationSucceeded);
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-backup-replication-refresh')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-backup-replication-refresh')),
      );
      await tester.pumpAndSettle();

      expect(harness.api.replicationCalls, 1);
      expect(find.text('Off-site encrypted backup copies'), findsOneWidget);
      expect(find.text('Remote replication'), findsOneWidget);
      expect(find.text('Configured'), findsOneWidget);
      expect(find.text('Remote copy verified'), findsOneWidget);
      expect(find.textContaining('4.0 KiB (4,096 bytes)'), findsOneWidget);
      expect(find.textContaining('private-backup-bucket'), findsNothing);
      expect(find.textContaining('secret.endpoint.invalid'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin can check only configured bucket access', (tester) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pumpSettings(tester, harness.app);
      expect(
        find.textContaining('The access check performs HeadBucket only'),
        findsOneWidget,
      );
      final button = find.byKey(
        const ValueKey('admin-backup-replication-preflight'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(harness.api.bucketAccessCheckCalls, 1);
      expect(
        find.text(
          'Bucket access verified with HeadBucket. This check does not verify uploads, multipart operations, restore, or provider-wide interoperability.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private-backup-bucket'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('bucket access failure hides provider diagnostics', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.bucketAccessCheckError = const ApiException(
      statusCode: 503,
      code: 'BACKUP_REPLICATION_CHECK_FAILED',
      message: 'provider endpoint secret.invalid rejected signing key',
    );
    try {
      await _pumpSettings(tester, harness.app);
      final button = find.byKey(
        const ValueKey('admin-backup-replication-preflight'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The server could not verify access to the configured S3 backup bucket.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('secret.invalid'), findsNothing);
      expect(
        find.textContaining(
          'provider endpoint secret.invalid rejected signing key',
        ),
        findsNothing,
      );
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('failed backup status shows only a fixed failure category', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.response = Future.value(
      InstanceAdminBackupStatus.fromJson(_failureStatus),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup status'));
      await tester.tap(find.text('Load backup status'));
      await tester.pumpAndSettle();
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Backup command failed'), findsOneWidget);
      expect(find.textContaining('/private/'), findsNothing);
      expect(find.textContaining('operator-backup.key'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('empty status and endpoint failure both have a refresh path', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load backup status'));
      await tester.tap(find.text('Load backup status'));
      await tester.pumpAndSettle();
      expect(
        find.text('No CLI or server-triggered backup attempt recorded.'),
        findsOneWidget,
      );
      expect(find.text('Refresh backup status'), findsOneWidget);

      harness.api.error = const ApiException(
        statusCode: 403,
        code: 'INSTANCE_ADMIN_REQUIRED',
        message: 'Instance admin access is required.',
      );
      await tester.tap(find.text('Refresh backup status'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load backup command status:'), findsOneWidget);
      expect(find.text('Refresh backup status'), findsOneWidget);
      expect(harness.api.calls, 2);
    } finally {
      await _dispose(tester, harness);
    }
  });
}

final _replicationSucceeded = <String, dynamic>{
  'operation': 'backup_replication',
  'configured': true,
  'pending_count': 0,
  'latest_attempt': {
    'archive_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'state': 'succeeded',
    'attempted_at': '2026-10-04T12:00:00Z',
    'completed_at': '2026-10-04T12:01:00Z',
    'archive_bytes': 4096,
    'failure_category': null,
  },
};

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
              'backup_status',
              'backup_replication',
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

  Future<InstanceAdminBackupStatus>? response;
  ApiException? error;
  int calls = 0;
  InstanceAdminBackupReplicationStatus? replicationResponse;
  int replicationCalls = 0;
  int bucketAccessCheckCalls = 0;
  ApiException? bucketAccessCheckError;

  @override
  Future<InstanceAdminBackupStatus> instanceAdminBackupStatus() async {
    calls++;
    if (error case final value?) throw value;
    return response ??
        InstanceAdminBackupStatus.fromJson({
          'operation': 'backup',
          'last_attempt': null,
        });
  }

  @override
  Future<InstanceAdminBackupReplicationStatus>
  instanceAdminBackupReplicationStatus() async {
    replicationCalls++;
    return replicationResponse ??
        InstanceAdminBackupReplicationStatus.fromJson({
          'operation': 'backup_replication',
          'configured': false,
          'pending_count': 0,
          'latest_attempt': null,
        });
  }

  @override
  Future<InstanceAdminBackupBucketAccessCheck>
  instanceAdminBackupBucketAccessCheck() async {
    bucketAccessCheckCalls++;
    if (bucketAccessCheckError case final value?) throw value;
    return const InstanceAdminBackupBucketAccessCheck();
  }
}

final _successStatus = <String, dynamic>{
  'operation': 'backup',
  'last_attempt': {
    'attempted_at': '2026-09-30T12:00:00Z',
    'result': 'succeeded',
    'migration_version': 23,
    'archive_bytes': 4096,
    'failure_category': null,
  },
};

final _failureStatus = <String, dynamic>{
  'operation': 'backup',
  'last_attempt': {
    'attempted_at': '2026-09-30T12:05:00Z',
    'result': 'failed',
    'migration_version': null,
    'archive_bytes': null,
    'failure_category': 'backup_failed',
  },
};
