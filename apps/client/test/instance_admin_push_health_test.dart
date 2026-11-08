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

  test('push health API is an authenticated read-only GET', () async {
    late http.Request captured;
    final api = ApiClient(
      baseUrl: 'https://admin.example.test/prefix',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_healthJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      final health = await api.instanceAdminPushHealth();
      expect(captured.method, 'GET');
      expect(captured.url.path, '/prefix/api/v1/admin/push-health');
      expect(captured.headers['authorization'], 'Bearer session-access-token');
      expect(health.generatedAt, DateTime.utc(2026, 10, 11, 12));
      expect(health.deliveryStartDateUtc, '2026-10-05');
      expect(health.deliveryEndDateUtc, '2026-10-11');
      expect(health.providers.map((provider) => provider.provider), [
        'apns',
        'fcm_v1',
      ]);
      expect(health.providers.first.configured, isTrue);
      expect(health.providers.first.registeredEndpoints, 3);
      expect(health.providers.last.deadLettered, 2);
      expect(health.providers.first.deliveryResults.accepted, 12);
      expect(health.providers.first.deliveryResults.retryableFailure, 3);
    } finally {
      api.close();
    }
  });

  test('push health parser enforces closed aggregate-only provider schema', () {
    final parsed = InstanceAdminPushHealth.fromJson(_healthJson);
    expect(parsed.providers, hasLength(2));
    final legacy = jsonDecode(jsonEncode(_healthJson)) as Map;
    legacy.remove('delivery_window');
    for (final provider in legacy['providers'] as List) {
      (provider as Map).remove('delivery_results');
    }
    final legacyParsed = InstanceAdminPushHealth.fromJson(
      Map<String, dynamic>.from(legacy),
    );
    expect(legacyParsed.deliveryWindowAvailable, isFalse);
    expect(legacyParsed.providers.first.deliveryResultsAvailable, isFalse);
    final missingProvider = jsonDecode(jsonEncode(_healthJson)) as Map;
    (missingProvider['providers'] as List).removeLast();
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(missingProvider),
      ),
      throwsFormatException,
    );
    final reversedProviders = jsonDecode(jsonEncode(_healthJson)) as Map;
    (reversedProviders['providers'] as List).setAll(
      0,
      (reversedProviders['providers'] as List).reversed.toList(),
    );
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(reversedProviders),
      ),
      throwsFormatException,
    );
    expect(
      () => InstanceAdminPushHealth.fromJson({..._healthJson, 'users': []}),
      throwsFormatException,
    );

    final withEndpointIdentity = jsonDecode(jsonEncode(_healthJson)) as Map;
    ((withEndpointIdentity['providers'] as List).first as Map)['device_id'] =
        'device-secret';
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(withEndpointIdentity),
      ),
      throwsFormatException,
    );

    final unknownProvider = jsonDecode(jsonEncode(_healthJson)) as Map;
    ((unknownProvider['providers'] as List).first as Map)['provider'] =
        'custom';
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(unknownProvider),
      ),
      throwsFormatException,
    );

    final negativeCount = jsonDecode(jsonEncode(_healthJson)) as Map;
    ((negativeCount['providers'] as List).first as Map)['due'] = -1;
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(negativeCount),
      ),
      throwsFormatException,
    );

    final duplicateProvider = jsonDecode(jsonEncode(_healthJson)) as Map;
    (duplicateProvider['providers'] as List)[1] = jsonDecode(
      jsonEncode((duplicateProvider['providers'] as List).first),
    );
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(duplicateProvider),
      ),
      throwsFormatException,
    );

    final invalidWindow = jsonDecode(jsonEncode(_healthJson)) as Map;
    (invalidWindow['delivery_window'] as Map)['days'] = 8;
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(invalidWindow),
      ),
      throwsFormatException,
    );
    final invalidDeliveryResult = jsonDecode(jsonEncode(_healthJson)) as Map;
    (((invalidDeliveryResult['providers'] as List).first
                as Map)['delivery_results']
            as Map)['accepted'] =
        -1;
    expect(
      () => InstanceAdminPushHealth.fromJson(
        Map<String, dynamic>.from(invalidDeliveryResult),
      ),
      throwsFormatException,
    );
  });

  testWidgets('non-admin cannot see or request push health', (tester) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Push provider health'), findsNothing);
      expect(
        find.byKey(const ValueKey('admin_push_health_load')),
        findsNothing,
      );
      expect(harness.api.calls, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('admin loads aggregate status and can retry a failed refresh', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    final pending = Completer<InstanceAdminPushHealth>();
    harness.api.response = pending.future;
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Push provider health'), findsOneWidget);
      expect(find.text('Load push health'), findsOneWidget);
      await tester.ensureVisible(find.text('Load push health'));
      await tester.tap(find.text('Load push health'));
      await tester.pump();
      expect(find.text('Reading push service status…'), findsOneWidget);
      expect(harness.api.calls, 1);

      pending.complete(InstanceAdminPushHealth.fromJson(_healthJson));
      await tester.pumpAndSettle();
      expect(find.text('APNs'), findsOneWidget);
      expect(find.text('FCM HTTP v1'), findsOneWidget);
      expect(find.text('Configured'), findsOneWidget);
      expect(find.text('Not configured'), findsAtLeastNWidgets(1));
      expect(find.text('Registered endpoints'), findsNWidgets(2));
      expect(find.text('Due'), findsNWidgets(2));
      expect(find.text('Retry waiting'), findsNWidgets(2));
      expect(find.text('Leased'), findsNWidgets(2));
      expect(find.text('Dead-lettered'), findsNWidgets(2));
      expect(find.text('Accepted by adapter (7 UTC days)'), findsNWidgets(2));
      expect(find.text('Invalid token (7 UTC days)'), findsNWidgets(2));
      expect(find.text('Retryable failure (7 UTC days)'), findsNWidgets(2));
      expect(find.textContaining('2026-10-05 – 2026-10-11'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.textContaining('best-effort wake-up hint'), findsOneWidget);
      expect(find.text('device-secret'), findsNothing);

      harness.api.error = const ApiException(
        statusCode: 503,
        code: 'PUSH_HEALTH_UNAVAILABLE',
        message: 'Push health snapshot is temporarily unavailable.',
      );
      await tester.ensureVisible(find.text('Refresh push health'));
      await tester.tap(find.text('Refresh push health'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load push service status:'), findsOneWidget);
      expect(find.text('Refresh push health'), findsOneWidget);

      harness.api.error = null;
      harness.api.response = Future.value(
        InstanceAdminPushHealth.fromJson(_healthJson),
      );
      await tester.tap(find.text('Refresh push health'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load push service status:'), findsNothing);
      expect(harness.api.calls, 3);

      harness.api.error = const ApiException(
        statusCode: 403,
        code: 'INSTANCE_ADMIN_REQUIRED',
        message: 'Instance admin access is required.',
      );
      await tester.tap(find.text('Refresh push health'));
      await tester.pumpAndSettle();
      expect(find.text('APNs'), findsNothing);
      expect(find.text('3'), findsNothing);
      expect(find.textContaining('Couldn\'t load push service status:'), findsOneWidget);
      expect(harness.api.calls, 4);
    } finally {
      if (!pending.isCompleted) pending.completeError(StateError('disposed'));
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

  Future<InstanceAdminPushHealth>? response;
  ApiException? error;
  int calls = 0;

  @override
  Future<InstanceAdminPushHealth> instanceAdminPushHealth() async {
    calls++;
    if (error case final value?) throw value;
    if (response != null) return response!;
    return InstanceAdminPushHealth.fromJson(_healthJson);
  }
}

final _healthJson = <String, dynamic>{
  'generated_at': '2026-10-11T12:00:00Z',
  'delivery_window': {
    'days': 7,
    'start_date_utc': '2026-10-05',
    'end_date_utc': '2026-10-11',
  },
  'providers': [
    {
      'provider': 'apns',
      'configured': true,
      'registered_endpoints': 3,
      'due': 1,
      'retry_waiting': 2,
      'leased': 0,
      'dead_lettered': 0,
      'delivery_results': {
        'accepted': 12,
        'invalid_token': 1,
        'retryable_failure': 3,
      },
    },
    {
      'provider': 'fcm_v1',
      'configured': false,
      'registered_endpoints': 0,
      'due': 0,
      'retry_waiting': 0,
      'leased': 0,
      'dead_lettered': 2,
      'delivery_results': {
        'accepted': 0,
        'invalid_token': 0,
        'retryable_failure': 0,
      },
    },
  ],
};
