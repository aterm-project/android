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

const _actorUserId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _actorDeviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _rawVaultId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _resourceHmac =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('admin audit API sends auth, limit and opaque cursor', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://admin-audit.example.test/prefix',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'events': [_eventJson()],
            'next_cursor': 'opaque.next/cursor+',
            'has_more': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      final firstPage = await api.adminAudit();
      expect(requests.single.url.path, '/prefix/api/v1/admin/audit');
      expect(requests.single.url.queryParameters, {'limit': '100'});
      expect(
        requests.single.headers['authorization'],
        'Bearer session-access-token',
      );
      expect(firstPage.hasMore, isTrue);
      expect(firstPage.events.single.scope, 'instance');
      expect(firstPage.events.single.resourceIdHmac, _resourceHmac);
      expect(firstPage.events.single.result, 'failure');

      final nextPage = await api.adminAudit(
        cursor: firstPage.nextCursor,
        limit: 100,
      );
      expect(requests.last.url.queryParameters, {
        'limit': '100',
        'cursor': 'opaque.next/cursor+',
      });
      expect(nextPage.events.single.action, 'admin.vault_quota_set');
      await expectLater(api.adminAudit(limit: 201), throwsArgumentError);
    } finally {
      api.close();
    }
  });

  test('instance audit parser rejects a raw Vault UUID in resource_id', () {
    expect(
      () => InstanceAdminAuditEvent.fromJson({
        ..._eventJson(),
        'resource_id': _rawVaultId,
      }),
      throwsFormatException,
    );
  });

  testWidgets('instance admin audit is hidden for non-admin accounts', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance admin audit'), findsNothing);
      expect(find.byTooltip('Load admin audit'), findsNothing);
      expect(harness.api.requests, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'admin audit loads, paginates both directions and renders HMAC IDs',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final pendingPage = Completer<InstanceAdminAuditPage>();
      harness.api.pendingPage = pendingPage.future;
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Instance admin audit'), findsOneWidget);
        harness.api.pages.addAll([
          _page([
            _event(
              eventId: '42',
              action: 'maintenance.backup.completed',
              actorUserId: null,
              actorDeviceId: null,
              resourceIdHmac: null,
              result: 'success',
              source: 'maintenance',
            ),
          ]),
          _page([_event()]),
        ]);

        await tester.ensureVisible(find.byTooltip('Load admin audit'));
        await tester.tap(find.byTooltip('Load admin audit'));
        await tester.pump();
        expect(find.text('Reading instance admin audit records…'), findsOneWidget);
        pendingPage.complete(_page([_event()]));
        await tester.pumpAndSettle();
        expect(find.text('An administrator changed the Vault quota'), findsOneWidget);
        expect(find.text('admin.vault_quota_set'), findsNothing);
        expect(find.text(_actorUserId), findsOneWidget);
        expect(find.text(_actorDeviceId), findsOneWidget);
        expect(find.text(_resourceHmac), findsOneWidget);
        expect(find.text('Resource ID (HMAC-SHA-256)'), findsOneWidget);
        expect(find.text('Occurred at'), findsOneWidget);
        expect(find.text('Source'), findsOneWidget);
        expect(find.text('API'), findsOneWidget);
        expect(find.text('Failed'), findsOneWidget);
        expect(find.text('failure'), findsNothing);
        expect(find.text(_rawVaultId), findsNothing);
        expect(harness.api.requests, [(100, null)]);

        await tester.ensureVisible(find.text('Next').first);
        await tester.tap(find.text('Next').first);
        await tester.pumpAndSettle();
        expect(harness.api.requests, [(100, null), (100, 'opaque-page-2')]);
        expect(find.text('Backup completed'), findsOneWidget);
        expect(find.text('Succeeded'), findsOneWidget);
        expect(find.text('success'), findsNothing);
        expect(find.text('maintenance.backup.completed'), findsNothing);
        expect(find.text(_actorUserId), findsNothing);
        expect(find.text(_rawVaultId), findsNothing);

        await tester.ensureVisible(find.text('Previous').first);
        await tester.tap(find.text('Previous').first);
        await tester.pumpAndSettle();
        expect(harness.api.requests, [
          (100, null),
          (100, 'opaque-page-2'),
          (100, null),
        ]);
        expect(find.text('An administrator changed the Vault quota'), findsOneWidget);
      } finally {
        if (!pendingPage.isCompleted) {
          pendingPage.completeError(StateError('test disposed'));
        }
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('every current instance admin action has a localized label', (
    tester,
  ) async {
    final actions = <(String, String)>[
      ('admin.account_disabled', 'An administrator disabled the account'),
      ('admin.account_enabled', 'An administrator enabled the account'),
      ('admin.account_session_revoked', 'An administrator revoked an account session'),
      ('admin.account_sessions_revoked', "An administrator revoked all of the account's sessions"),
      ('admin.backup_completed', 'Admin backup completed'),
      ('admin.backup_failed', 'Admin backup failed'),
      ('admin.backup_interrupted', 'Admin backup interrupted'),
      ('admin.backup_requested', 'An administrator requested a backup'),
      ('admin.backup_schedule_updated', 'An administrator changed the scheduled backup'),
      ('admin.backup_started', 'Admin backup started'),
      ('admin.maintenance_completed', 'Admin maintenance job completed'),
      ('admin.maintenance_failed', 'Admin maintenance job failed'),
      ('admin.maintenance_interrupted', 'Admin maintenance job interrupted'),
      ('admin.maintenance_requested', 'An administrator requested a maintenance job'),
      ('admin.maintenance_started', 'Admin maintenance job started'),
      ('admin.relay_policy_updated', 'An administrator updated the SSH Relay policy'),
      ('admin.restore_completed', 'Admin restore job completed'),
      ('admin.restore_failed', 'Admin restore job failed'),
      ('admin.restore_interrupted', 'Admin restore job interrupted'),
      ('admin.restore_requested', 'An administrator requested a restore job'),
      ('admin.restore_stage_discarded', 'An administrator discarded the isolated restore copy'),
      ('admin.restore_started', 'Admin restore job started'),
      ('admin.vault_quota_set', 'An administrator changed the Vault quota'),
      ('instance.account_invitation_issued', 'Instance admin invitation issued'),
      ('instance.account_invitation_revoked', 'Instance admin invitation revoked'),
    ];
    expect(actions, hasLength(25));
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _page([
        for (var index = 0; index < actions.length; index++)
          _event(
            eventId: '${index + 1}',
            action: actions[index].$1,
            source:
                actions[index].$1.startsWith('admin.maintenance_') ||
                    (actions[index].$1.startsWith('admin.restore_') &&
                        actions[index].$1 != 'admin.restore_stage_discarded') ||
                    (actions[index].$1.startsWith('admin.backup_') &&
                        actions[index].$1 != 'admin.backup_schedule_updated')
                ? 'maintenance'
                : 'api',
          ),
      ]),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.byTooltip('Load admin audit'));
      await tester.tap(find.byTooltip('Load admin audit'));
      await tester.pumpAndSettle();
      for (final (action, label) in actions) {
        expect(find.text(label), findsOneWidget, reason: action);
        expect(find.text(action), findsNothing, reason: action);
      }
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin audit API errors expose a first-page retry', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.errors.add(
      const ApiException(
        statusCode: 403,
        code: 'INSTANCE_ADMIN_REQUIRED',
        message: 'Instance admin access is required.',
      ),
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.byTooltip('Load admin audit'));
      await tester.tap(find.byTooltip('Load admin audit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load instance admin audit records:'), findsOneWidget);
      expect(
        find.textContaining('Instance admin access is required.'),
        findsOneWidget,
      );
      expect(find.text('Reload first page'), findsOneWidget);

      harness.api.pages.add(_page([_event()]));
      await tester.ensureVisible(find.text('Reload first page'));
      await tester.tap(find.text('Reload first page'));
      await tester.pumpAndSettle();
      expect(find.text('An administrator changed the Vault quota'), findsOneWidget);
      expect(harness.api.requests, [(100, null), (100, null)]);
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
    await openSettingsCategory(tester, 'audit', ifAvailable: true);
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
  final _WidgetAdminAuditApi api;
  final AppController app;

  static Future<_Harness> create(
    SodiumSumo sodium, {
    required bool isAdmin,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetAdminAuditApi();
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

class _WidgetAdminAuditApi extends ApiClient {
  _WidgetAdminAuditApi()
    : super(
        baseUrl: 'https://admin-audit-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final List<(int, String?)> requests = [];
  final List<InstanceAdminAuditPage> pages = [];
  final List<ApiException> errors = [];
  Future<InstanceAdminAuditPage>? pendingPage;

  @override
  Future<AdminMaintenanceJobsPage> adminMaintenanceJobs({
    int limit = 50,
    int offset = 0,
  }) async => AdminMaintenanceJobsPage(
    jobs: const [],
    total: 0,
    limit: limit,
    offset: offset,
    supportedActions: const ['maintenance'],
  );

  @override
  Future<InstanceAdminAuditPage> adminAudit({
    String? cursor,
    int limit = 100,
  }) async {
    requests.add((limit, cursor));
    if (errors.isNotEmpty) throw errors.removeAt(0);
    if (pendingPage case final request?) {
      pendingPage = null;
      return request;
    }
    if (pages.isEmpty)
      throw StateError('No fake instance audit page configured');
    return pages.removeAt(0);
  }
}

InstanceAdminAuditPage _page(List<InstanceAdminAuditEvent> events) =>
    InstanceAdminAuditPage(
      events: events,
      nextCursor: 'opaque-page-2',
      hasMore: events.isNotEmpty,
    );

InstanceAdminAuditEvent _event({
  String eventId = '41',
  String action = 'admin.vault_quota_set',
  String? actorUserId = _actorUserId,
  String? actorDeviceId = _actorDeviceId,
  String? resourceIdHmac = _resourceHmac,
  String result = 'failure',
  String source = 'api',
}) => InstanceAdminAuditEvent(
  eventId: eventId,
  scope: 'instance',
  actorUserId: actorUserId,
  actorDeviceId: actorDeviceId,
  action: action,
  resourceType: 'vault',
  resourceIdHmac: resourceIdHmac,
  result: result,
  occurredAt: DateTime.utc(2026, 9, 29, 13, 45),
  source: source,
);

Map<String, dynamic> _eventJson() => {
  'event_id': '41',
  'scope': 'instance',
  'actor_user_id': _actorUserId,
  'actor_device_id': _actorDeviceId,
  'action': 'admin.vault_quota_set',
  'resource_type': 'vault',
  'resource_id': _resourceHmac,
  'result': 'failure',
  'occurred_at': '2026-09-29T13:45:00Z',
  'source': 'api',
};
