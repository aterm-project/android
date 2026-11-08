import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/device_redaction_capability.dart';
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

const _activeDeviceId = '11111111-1111-4111-8111-111111111111';
const _revokedDeviceId = '22222222-2222-4222-8222-222222222222';
const _unknownDeviceId = '33333333-3333-4333-8333-333333333333';
const _invalidCapabilityDeviceId = '44444444-4444-4444-8444-444444444444';
const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'device rows show server status, timestamps and current identity',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.devices
            ..identity = DeviceIdentity.create(sodium);
      app.devices = [
        _device(
          app.identity!.deviceId,
          name: 'This Browser',
          status: 'active',
          createdAt: '2026-09-01T12:34:00Z',
        ),
        _device(
          _activeDeviceId,
          name: 'Active Laptop',
          status: 'active',
          createdAt: '2026-09-02T12:34:00Z',
        ),
        _device(
          _revokedDeviceId,
          name: 'Old Tablet',
          status: 'revoked',
          createdAt: '2026-09-03T12:34:00Z',
          revokedAt: '2026-09-04T12:34:00Z',
        ),
        _device(
          _unknownDeviceId,
          name: 'Unrecognized state',
          status: 'pending',
        ),
      ];
      final semantics = tester.ensureSemantics();

      try {
        await tester.binding.setSurfaceSize(const Size(1200, 1000));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Active'), findsNWidgets(2));
        expect(find.text('Revoked'), findsOneWidget);
        expect(find.text('Status unavailable'), findsOneWidget);
        expect(find.textContaining('Created ·'), findsNWidgets(3));
        expect(find.textContaining('Revoked ·'), findsOneWidget);
        expect(find.bySemanticsLabel('Current device'), findsOneWidget);
        expect(find.byTooltip('Revoke device'), findsOneWidget);
        expect(find.text('Old Tablet'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'device page shows only capability reports verified against device keys',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final currentIdentity = DeviceIdentity.create(sodium);
      final verifiedIdentity = DeviceIdentity.create(sodium);
      final invalidIdentity = DeviceIdentity.create(sodium);
      final validReport = _signedCapabilityReport(
        sodium,
        verifiedIdentity,
        deviceId: _activeDeviceId,
      );
      final tamperedReport = Map<String, dynamic>.from(
        _signedCapabilityReport(
          sodium,
          invalidIdentity,
          deviceId: _invalidCapabilityDeviceId,
        ),
      )..['max_attachment_bytes'] = 777;
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.devices
            ..identity = currentIdentity
            ..session = AuthSession(
              accountId: _accountId,
              accessToken: 'test-access',
              expiresIn: 900,
              refreshToken: 'test-refresh',
              deviceId: currentIdentity.deviceId,
              vaults: const [],
            )
            ..devices = [
              _device(
                currentIdentity.deviceId,
                name: 'This Browser',
                status: 'active',
              ),
              _device(
                _activeDeviceId,
                name: 'Verified Laptop',
                status: 'active',
                userId: _accountId,
                signingPublicKey: encodeBase64Url(
                  verifiedIdentity.signing.publicKey,
                ),
                capabilityReport: validReport,
              ),
              _device(
                _invalidCapabilityDeviceId,
                name: 'Unverified Tablet',
                status: 'active',
                userId: _accountId,
                signingPublicKey: encodeBase64Url(
                  invalidIdentity.signing.publicKey,
                ),
                capabilityReport: tamperedReport,
              ),
              _device(_unknownDeviceId, name: 'Older Phone', status: 'active'),
            ];
      final semantics = tester.ensureSemantics();

      try {
        await tester.binding.setSurfaceSize(const Size(1200, 1000));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Verified capabilities · report revision 3'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Record schema ≤ 2 · attachment formats 1, 2 · '
            'attachment limit 1.0 GiB (1,073,741,824 bytes)',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Compatibility report · unverified; details hidden'),
          findsOneWidget,
        );
        expect(find.textContaining('777 bytes'), findsNothing);
        expect(
          find.text('Compatibility report · not reported'),
          findsNWidgets(2),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        verifiedIdentity.dispose();
        invalidIdentity.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'trusted devices shows Vault-scoped redaction readiness and excludes inactive rows',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final currentIdentity = DeviceIdentity.create(sodium);
      final readyIdentity = DeviceIdentity.create(sodium);
      final invalidatedIdentity = DeviceIdentity.create(sodium);
      final unsupportedIdentity = DeviceIdentity.create(sodium);
      final invalidIdentity = DeviceIdentity.create(sodium);
      const vaultId = '55555555-5555-4555-8555-555555555555';
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.devices
            ..identity = currentIdentity
            ..activeVault = const VaultDescriptor(
              id: vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..vaultDeviceRowsVaultId = vaultId
            ..vaultDeviceRows = [
              _redactionDevice(
                '66666666-6666-4666-8666-666666666666',
                'Ready device',
                readyIdentity,
                report: _signedRedactionReport(
                  sodium,
                  readyIdentity,
                  deviceId: '66666666-6666-4666-8666-666666666666',
                ),
              ),
              _redactionDevice(
                '77777777-7777-4777-8777-777777777777',
                'Missing report device',
                currentIdentity,
                report: null,
              ),
              _redactionDevice(
                '88888888-8888-4888-8888-888888888888',
                'Invalidated report device',
                invalidatedIdentity,
                report: _signedRedactionReport(
                  sodium,
                  invalidatedIdentity,
                  deviceId: '88888888-8888-4888-8888-888888888888',
                  invalidatedAt: '2026-10-12T10:00:00Z',
                ),
              ),
              _redactionDevice(
                '99999999-9999-4999-8999-999999999999',
                'Unsupported device',
                unsupportedIdentity,
                report: _signedRedactionReport(
                  sodium,
                  unsupportedIdentity,
                  deviceId: '99999999-9999-4999-8999-999999999999',
                  version: 2,
                ),
              ),
              _redactionDevice(
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                'Unverifiable device',
                invalidIdentity,
                report: _signedRedactionReport(
                  sodium,
                  currentIdentity,
                  deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                ),
              ),
              _redactionDevice(
                'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                'Revoked device',
                currentIdentity,
                status: 'revoked',
                report: null,
              ),
              _redactionDevice(
                'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
                'Archived device',
                currentIdentity,
                membershipStatus: 'archived',
                report: null,
              ),
            ];

      try {
        await _pumpDevices(tester, app);

        expect(find.text('Redaction readiness'), findsOneWidget);
        expect(find.text('Ready'), findsOneWidget);
        expect(find.text('Report not received'), findsOneWidget);
        expect(find.text('Report expired or invalidated'), findsOneWidget);
        expect(find.text('Report could not be verified'), findsOneWidget);
        expect(find.text('Client version unsupported'), findsOneWidget);
        expect(find.text('Revoked device'), findsNothing);
        expect(find.text('Archived device'), findsNothing);
        expect(find.text('Account devices'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('vault_redaction_readiness_refresh')),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        currentIdentity.dispose();
        readyIdentity.dispose();
        invalidatedIdentity.dispose();
        unsupportedIdentity.dispose();
        invalidIdentity.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('cancel leaves active device unchanged and sends no request', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final semantics = tester.ensureSemantics();
    try {
      await _pumpDevices(tester, harness.app);
      final revoke = find.byTooltip('Revoke device');
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();

      expect(find.text('Revoke device?'), findsOneWidget);
      expect(
        find.text(
          'Active Laptop will lose account access, and its active sessions will be revoked.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(harness.requests, isEmpty);
      expect(find.text('Active'), findsOneWidget);
      expect(find.byTooltip('Revoke device'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await harness.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('confirm calls revoke API and renders refreshed server state', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final semantics = tester.ensureSemantics();
    try {
      await _pumpDevices(tester, harness.app);
      final revoke = find.byTooltip('Revoke device');
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke device').last);
      await tester.pumpAndSettle();

      expect(
        harness.requests.map((request) => request.method),
        containsAllInOrder(['POST', 'GET']),
      );
      expect(
        harness.requests.first.url.path,
        '/api/v1/devices/$_activeDeviceId/revoke',
      );
      expect(find.text('Revoked'), findsOneWidget);
      expect(find.textContaining('Revoked ·'), findsOneWidget);
      expect(find.byTooltip('Revoke device'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await harness.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('account device revocation is available during Vault recovery', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final semantics = tester.ensureSemantics();
    try {
      harness.app.snapshotRecoveryActive = true;
      await _pumpDevices(tester, harness.app);
      final revoke = find.byTooltip('Revoke device');
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke device').last);
      await tester.pumpAndSettle();

      expect(
        harness.requests.map((request) => request.method),
        containsAllInOrder(['POST', 'GET']),
      );
      expect(
        harness.requests.first.url.path,
        '/api/v1/devices/$_activeDeviceId/revoke',
      );
      expect(find.text('Revoked'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await harness.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('failed device refresh is surfaced without a Web error', (
    tester,
  ) async {
    final harness = await _makeHarness(rejectDeviceRead: true);
    final semantics = tester.ensureSemantics();
    try {
      harness.app.devices = [];
      await _pumpDevices(tester, harness.app);

      await tester.tap(find.text('Refresh devices'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('The sign-in state expired. Sign in again.'), findsOneWidget);
      expect(harness.app.devices, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await harness.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('failed background device load is contained and surfaced', (
    tester,
  ) async {
    final harness = await _makeHarness(rejectDeviceRead: true);
    final semantics = tester.ensureSemantics();
    try {
      harness.app
        ..devices = []
        ..page = WorkspacePage.hosts;
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      harness.app.showWorkspacePage(WorkspacePage.devices);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('The sign-in state expired. Sign in again.'), findsOneWidget);
      expect(find.text('Trusted devices'), findsAtLeastNWidgets(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await harness.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

Map<String, dynamic> _device(
  String id, {
  required String name,
  required String status,
  String? createdAt,
  String? revokedAt,
  String? userId,
  String? signingPublicKey,
  Map<String, dynamic>? capabilityReport,
}) => {
  'device_id': id,
  if (userId != null) 'user_id': userId,
  'name': name,
  'status': status,
  'signing_public_key': signingPublicKey ?? 'c2lnbmluZy1rZXktcHVibGlj',
  if (createdAt != null) 'created_at': createdAt,
  if (revokedAt != null) 'revoked_at': revokedAt,
  if (capabilityReport != null) 'capability_report': capabilityReport,
};

Map<String, dynamic> _signedCapabilityReport(
  SodiumSumo sodium,
  DeviceIdentity signer, {
  required String deviceId,
}) {
  final unsigned = <String, Object?>{
    'account_id': _accountId,
    'device_id': deviceId,
    'revision': 3,
    'max_record_schema': 2,
    'host_attachment_manifest_versions': [1, 2],
    'max_attachment_bytes': 1024 * 1024 * 1024,
  };
  final signature = sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
    secretKey: signer.signing.secretKey,
  );
  return {...unsigned, 'signature': encodeBase64Url(signature)};
}

Map<String, dynamic> _redactionDevice(
  String deviceId,
  String name,
  DeviceIdentity identity, {
  required Map<String, dynamic>? report,
  String status = 'active',
  String membershipStatus = 'active',
}) => {
  'device_id': deviceId,
  'user_id': _accountId,
  'name': name,
  'signing_public_key': encodeBase64Url(identity.signing.publicKey),
  'status': status,
  'membership_status': membershipStatus,
  'redaction_capability_report': report,
};

Map<String, dynamic> _signedRedactionReport(
  SodiumSumo sodium,
  DeviceIdentity signer, {
  required String deviceId,
  int version = 1,
  String? invalidatedAt,
}) {
  final unsigned = <String, Object?>{
    'format': deviceRedactionCapabilityFormat,
    'account_id': _accountId,
    'device_id': deviceId,
    'revision': 3,
    'sync_redaction_version': version,
  };
  final signature = sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
    secretKey: signer.signing.secretKey,
  );
  return {
    ...unsigned,
    'signature': encodeBase64Url(signature),
    'invalidated_at': invalidatedAt,
  };
}

Future<_DeviceHarness> _makeHarness({bool rejectDeviceRead = false}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final serverDevices = [
    _device(
      _activeDeviceId,
      name: 'Active Laptop',
      status: 'active',
      createdAt: '2026-09-02T12:34:00Z',
    ),
  ];
  final requests = <http.Request>[];
  final api = ApiClient(
    baseUrl: 'https://devices.example.test',
    client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path == '/api/v1/devices/$_activeDeviceId/revoke') {
        serverDevices[0] = _device(
          _activeDeviceId,
          name: 'Active Laptop',
          status: 'revoked',
          createdAt: '2026-09-02T12:34:00Z',
          revokedAt: '2026-09-28T15:00:00Z',
        );
        return http.Response('{}', 200);
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/devices') {
        if (rejectDeviceRead) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'AUTH_REQUIRED',
                'message': 'Authentication required.',
              },
            }),
            401,
          );
        }
        return http.Response(jsonEncode({'devices': serverDevices}), 200);
      }
      return http.Response('{}', 404);
    }),
  )..accessToken = 'test-token';
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.devices
        ..api = api
        ..identity = DeviceIdentity.create(sodium)
        ..devices = List<Map<String, dynamic>>.from(serverDevices);
  return _DeviceHarness(app: app, database: database, requests: requests);
}

Future<void> _pumpDevices(WidgetTester tester, AppController app) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pumpAndSettle();
}

class _DeviceHarness {
  const _DeviceHarness({
    required this.app,
    required this.database,
    required this.requests,
  });

  final AppController app;
  final ClientDatabase database;
  final List<http.Request> requests;

  Future<void> dispose() async {
    app.dispose();
    await database.close();
  }
}
