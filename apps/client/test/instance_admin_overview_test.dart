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

  test(
    'overview API uses the authenticated endpoint and parses all sections',
    () async {
      late http.Request captured;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_overviewJson),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final overview = await api.instanceAdminOverview();

        expect(captured.method, 'GET');
        expect(captured.url.path, '/prefix/api/v1/admin/overview');
        expect(
          captured.headers['authorization'],
          'Bearer session-access-token',
        );
        expect(overview.instanceId, 'instance-123');
        expect(overview.serverSpaceId, 'space-456');
        expect(overview.generation, '7');
        expect(overview.accountsTotal, 12);
        expect(overview.accountsDisabled, 1);
        expect(overview.devicesActive, 8);
        expect(overview.storedBytes, 2048);
        expect(overview.relayEnabled, isTrue);
        expect(overview.relayAllowCidrs, ['10.0.0.0/8']);
        expect(overview.relayAllowPorts, [22, 2222]);
        expect(overview.relayMaxConnectionsPerUser, 3);
        expect(overview.generatedAt, DateTime.utc(2026, 9, 29, 12, 30));
      } finally {
        api.close();
      }
    },
  );

  testWidgets('instance admin overview is hidden when policy denies access', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance admin overview'), findsNothing);
      expect(find.text('Load overview'), findsNothing);
      expect(harness.api.calls, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('allowlisted account loads and renders instance overview', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    final pending = Completer<InstanceAdminOverview>();
    harness.api.response = pending.future;
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance admin overview'), findsOneWidget);
      await tester.ensureVisible(find.text('Load overview'));
      await tester.tap(find.text('Load overview'));
      await tester.pump();
      expect(find.text('Reading instance overview…'), findsOneWidget);

      pending.complete(InstanceAdminOverview.fromJson(_overviewJson));
      await tester.pumpAndSettle();
      expect(find.text('instance-123'), findsOneWidget);
      expect(find.text('space-456'), findsOneWidget);
      expect(find.textContaining('12 total'), findsOneWidget);
      expect(find.textContaining('1 disabled'), findsOneWidget);
      expect(find.textContaining('2.0 KiB'), findsOneWidget);
      expect(find.text('10.0.0.0/8'), findsOneWidget);
      expect(find.text('22, 2222'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      expect(find.text('Load overview'), findsNothing);
      expect(find.text('Refresh overview'), findsOneWidget);
      expect(harness.api.calls, 1);
    } finally {
      if (!pending.isCompleted) pending.completeError(StateError('disposed'));
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin endpoint access error is shown with a retry action', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.error = const ApiException(
      statusCode: 403,
      code: 'INSTANCE_ADMIN_REQUIRED',
      message: 'Instance admin access is required.',
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load overview'));
      await tester.tap(find.text('Load overview'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load instance overview:'), findsOneWidget);
      expect(
        find.textContaining('Instance admin access is required.'),
        findsOneWidget,
      );
      expect(find.text('Load overview'), findsOneWidget);
      expect(harness.api.calls, 1);
    } finally {
      await _dispose(tester, harness);
    }
  });

  test('overview requires the disabled account count', () {
    final counts = Map<String, dynamic>.from(_overviewJson['counts'] as Map)
      ..remove('accounts_disabled');
    final missingDisabledCount = Map<String, dynamic>.from(_overviewJson)
      ..['counts'] = counts;
    expect(
      () => InstanceAdminOverview.fromJson(missingDisabledCount),
      throwsFormatException,
    );
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
    await openSettingsCategory(tester, 'instance', ifAvailable: true);
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

  Future<InstanceAdminOverview>? response;
  ApiException? error;
  int calls = 0;

  @override
  Future<InstanceAdminOverview> instanceAdminOverview() async {
    calls++;
    if (error case final value?) throw value;
    if (response != null) return response!;
    return InstanceAdminOverview.fromJson(_overviewJson);
  }
}

final _overviewJson = <String, dynamic>{
  'instance': {
    'instance_id': 'instance-123',
    'server_space_id': 'space-456',
    'generation': '7',
    'protocol_version': 2,
  },
  'counts': {
    'accounts_total': 12,
    'accounts_active': 10,
    'accounts_disabled': 1,
    'accounts_deleting': 2,
    'devices_active': 8,
    'vaults_active': 6,
    'vaults_deleting': 1,
    'stored_bytes': 2048,
    'reserved_upload_bytes': 512,
    'vault_quota_bytes': 1048576,
  },
  'relay': {
    'enabled': true,
    'allow_cidrs': ['10.0.0.0/8'],
    'allow_ports': [22, 2222],
    'max_connections_per_user': 3,
  },
  'generated_at': '2026-09-29T12:30:00Z',
};
