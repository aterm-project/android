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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'metrics credential API uses authenticated one-time endpoints',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          requests.add(request);
          final body = switch (request.method) {
            'GET' => {'active': true, 'updated_at': '2026-10-07T10:00:00Z'},
            'POST' => {
              'credential': 'atm_${'A' * 43}',
              'created_at': '2026-10-07T10:01:00Z',
            },
            'DELETE' => {'revoked': true},
            _ => throw StateError('Unexpected method ${request.method}'),
          };
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'admin-session-token';
      try {
        final status = await api.instanceAdminMetricsCredentialStatus();
        final rotation = await api.rotateInstanceAdminMetricsCredential();
        final revocation = await api.revokeInstanceAdminMetricsCredential();

        expect(status.active, isTrue);
        expect(status.updatedAt, DateTime.utc(2026, 10, 7, 10));
        expect(rotation.credential, 'atm_${'A' * 43}');
        expect(rotation.createdAt, DateTime.utc(2026, 10, 7, 10, 1));
        expect(revocation.revoked, isTrue);
        expect(requests.map((request) => request.method), [
          'GET',
          'POST',
          'DELETE',
        ]);
        expect(
          requests.map((request) => request.url.path),
          List.filled(3, '/prefix/api/v1/admin/metrics-credential'),
        );
        expect(
          requests.every(
            (request) =>
                request.headers['authorization'] ==
                'Bearer admin-session-token',
          ),
          isTrue,
        );
        expect(requests[1].body, isEmpty);
        expect(requests[2].body, isEmpty);
      } finally {
        api.close();
      }
    },
  );

  test('reloadable status cannot contain the plaintext credential', () {
    expect(
      () => InstanceAdminMetricsCredentialStatus.fromJson({
        'active': true,
        'updated_at': '2026-10-07T10:00:00Z',
        'credential': 'atm_${'A' * 43}',
      }),
      throwsFormatException,
    );
    expect(
      () => InstanceAdminMetricsCredentialRotation.fromJson({
        'credential': 'not-a-credential',
        'created_at': '2026-10-07T10:00:00Z',
      }),
      throwsFormatException,
    );
  });

  testWidgets('only instance admins can manage one-time scrape credentials', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Prometheus scrape credential'), findsNothing);
      expect(harness.api.statusCalls + harness.api.rotateCalls, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('credential can be loaded, rotated, shown once and revoked', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    final credential = 'atm_${'B' * 43}';
    harness.api.nextCredential = credential;
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-load')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-load')),
      );
      await tester.pumpAndSettle();
      expect(harness.app.instanceAdminMetricsCredentialStatus?.active, isFalse);
      expect(harness.api.statusCalls, 1);

      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-confirm-rotate')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save this credential now'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('admin-metrics-credential-value')),
        findsOneWidget,
      );
      expect(
        harness.app.instanceAdminMetricsCredentialOneTimeValue,
        credential,
      );
      expect(harness.api.rotateCalls, 1);
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-saved')),
      );
      await tester.pumpAndSettle();
      expect(harness.app.instanceAdminMetricsCredentialOneTimeValue, isNull);
      expect(find.text(credential), findsNothing);
      expect(harness.app.instanceAdminMetricsCredentialStatus?.active, isTrue);

      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-revoke')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-revoke')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-confirm-revoke')),
      );
      await tester.pumpAndSettle();

      expect(harness.api.revokeCalls, 1);
      expect(harness.app.instanceAdminMetricsCredentialStatus?.active, isFalse);
      expect(find.text('No active credential'), findsOneWidget);
      expect(find.text(credential), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('copy control writes each rotated one-time value', (
    tester,
  ) async {
    String? clipboardText;
    var clipboardWriteCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String;
            clipboardWriteCount++;
          }
          return null;
        });
    final harness = await _Harness.create(isAdmin: true);

    Future<void> rotateAndCopy(String syntheticValue) async {
      harness.api.nextCredential = syntheticValue;
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-confirm-rotate')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save this credential now'), findsOneWidget);
      expect(find.text('Copy credential'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-copy')),
      );
      await tester.pumpAndSettle();
      // Compare without putting the synthetic clipboard value in a failure log.
      expect(clipboardText == syntheticValue, isTrue);
      expect(find.text('Copied'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-saved')),
      );
      await tester.pumpAndSettle();
      expect(harness.app.instanceAdminMetricsCredentialOneTimeValue, isNull);
    }

    try {
      await _pumpSettings(tester, harness.app);
      await rotateAndCopy('atm_${'C' * 43}');
      await rotateAndCopy('atm_${'D' * 43}');
      expect(harness.api.rotateCalls, 2);
      expect(clipboardWriteCount, 2);
      expect(harness.app.instanceAdminMetricsCredentialOneTimeValue, isNull);
    } finally {
      await _dispose(tester, harness);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  testWidgets('clipboard failure offers manual selection fallback', (
    tester,
  ) async {
    final syntheticCredential = 'atm_${'E' * 43}';
    var clipboardWriteAttemptCount = 0;
    var failClipboardWrite = true;
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWriteAttemptCount++;
            if (failClipboardWrite) {
              failClipboardWrite = false;
              throw PlatformException(code: 'clipboard_unavailable');
            }
            clipboardText = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    final harness = await _Harness.create(isAdmin: true);

    try {
      harness.api.nextCredential = syntheticCredential;
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-confirm-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-copy')),
      );
      await tester.pumpAndSettle();

      expect(clipboardWriteAttemptCount, 1);
      expect(
        find.text('Copy failed; select the value manually'),
        findsOneWidget,
      );
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey('admin-metrics-credential-copy-status'),
              ),
            )
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('admin-metrics-credential-value')),
        findsOneWidget,
      );
      expect(
        find.text('If copying is unavailable, select the value above.'),
        findsOneWidget,
      );
      expect(
        harness.app.instanceAdminMetricsCredentialOneTimeValue ==
            syntheticCredential,
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-copy')),
      );
      await tester.pumpAndSettle();
      expect(clipboardWriteAttemptCount, 2);
      // Keep synthetic clipboard data out of test failure output.
      expect(clipboardText == syntheticCredential, isTrue);
      expect(find.text('Copy failed; select the value manually'), findsNothing);
      expect(find.text('Copied'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-saved')),
      );
      await tester.pumpAndSettle();
      expect(harness.app.instanceAdminMetricsCredentialOneTimeValue, isNull);
    } finally {
      await _dispose(tester, harness);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  testWidgets('clipboard write timeout offers manual selection fallback', (
    tester,
  ) async {
    final syntheticCredential = 'atm_${'F' * 43}';
    var clipboardWriteAttemptCount = 0;
    final pendingClipboardReply = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) {
          if (call.method == 'Clipboard.setData') {
            clipboardWriteAttemptCount++;
            return pendingClipboardReply.future;
          }
          return Future<Object?>.value(null);
        });
    final harness = await _Harness.create(isAdmin: true);

    try {
      harness.api.nextCredential = syntheticCredential;
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-confirm-rotate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('admin-metrics-credential-copy')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(clipboardWriteAttemptCount, 1);
      expect(
        find.text('Copy failed; select the value manually'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('admin-metrics-credential-value')),
        findsOneWidget,
      );
      expect(
        find.text('If copying is unavailable, select the value above.'),
        findsOneWidget,
      );
      expect(
        harness.app.instanceAdminMetricsCredentialOneTimeValue ==
            syntheticCredential,
        isTrue,
      );
    } finally {
      if (!pendingClipboardReply.isCompleted) {
        pendingClipboardReply.complete(null);
      }
      await _dispose(tester, harness);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
}

Future<void> _pumpSettings(WidgetTester tester, AppController app) async {
  tester.view.physicalSize = const Size(1200, 1100);
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
  final _WidgetMetricsApi api;
  final AppController app;

  static Future<_Harness> create({required bool isAdmin}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetMetricsApi();
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

class _WidgetMetricsApi extends ApiClient {
  _WidgetMetricsApi()
    : super(
        baseUrl: 'https://admin-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  int statusCalls = 0;
  int rotateCalls = 0;
  int revokeCalls = 0;
  String nextCredential = 'atm_${'A' * 43}';

  @override
  Future<InstanceAdminMetricsCredentialStatus>
  instanceAdminMetricsCredentialStatus() async {
    statusCalls++;
    return const InstanceAdminMetricsCredentialStatus(
      active: false,
      updatedAt: null,
    );
  }

  @override
  Future<InstanceAdminMetricsCredentialRotation>
  rotateInstanceAdminMetricsCredential() async {
    rotateCalls++;
    return InstanceAdminMetricsCredentialRotation(
      credential: nextCredential,
      createdAt: DateTime.utc(2026, 10, 7, 10),
    );
  }

  @override
  Future<InstanceAdminMetricsCredentialRevocation>
  revokeInstanceAdminMetricsCredential() async {
    revokeCalls++;
    return const InstanceAdminMetricsCredentialRevocation(revoked: true);
  }
}
