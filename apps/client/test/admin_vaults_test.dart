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

const _vaultId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _ownerId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _secondVaultId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'admin Vault API paginates and updates quota with session auth',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/proxy',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            final offset = int.parse(request.url.queryParameters['offset']!);
            return http.Response(
              jsonEncode({
                'vaults': [_vaultJson()],
                'total': 101,
                'limit': 50,
                'offset': offset,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'vault_id': _vaultId,
              'quota_bytes': 8192,
              'stored_bytes': 1024,
              'reserved_upload_bytes': 256,
              'updated_at': '2026-09-29T14:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final firstPage = await api.adminVaults();
        expect(firstPage.offset, 0);
        expect(requests.single.url.path, '/proxy/api/v1/admin/vaults');
        expect(requests.single.url.queryParameters, {
          'limit': '50',
          'offset': '0',
        });
        expect(
          requests.single.headers['authorization'],
          'Bearer session-access-token',
        );

        final page = await api.adminVaults(limit: 50, offset: 50);
        expect(page.total, 101);
        expect(page.limit, 50);
        expect(page.offset, 50);
        expect(page.hasPrevious, isTrue);
        expect(page.hasNext, isTrue);
        expect(page.vaults.single.ownerUsername, 'alice@example.test');
        expect(page.vaults.single.quotaBytes, 4096);
        expect(requests[1].url.path, '/proxy/api/v1/admin/vaults');
        expect(requests[1].url.queryParameters, {
          'limit': '50',
          'offset': '50',
        });
        expect(
          requests[1].headers['authorization'],
          'Bearer session-access-token',
        );

        final receipt = await api.updateAdminVaultQuota(
          vaultId: _vaultId,
          quotaBytes: 8192,
        );
        expect(receipt.vaultId, _vaultId);
        expect(receipt.quotaBytes, 8192);
        expect(requests.last.method, 'PUT');
        expect(
          requests.last.url.path,
          '/proxy/api/v1/admin/vaults/$_vaultId/quota',
        );
        expect(jsonDecode(requests.last.body), {'quota_bytes': 8192});
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );
        await expectLater(
          api.updateAdminVaultQuota(
            vaultId: _vaultId.toUpperCase(),
            quotaBytes: 8192,
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.updateAdminVaultQuota(vaultId: _vaultId, quotaBytes: 0),
          throwsArgumentError,
        );
        await expectLater(
          api.updateAdminVaultQuota(
            vaultId: _vaultId,
            quotaBytes: maxAdminVaultQuotaBytes + 1,
          ),
          throwsArgumentError,
        );
        await expectLater(api.adminVaults(limit: 101), throwsArgumentError);
        await expectLater(
          api.adminVaults(offset: 1000001),
          throwsArgumentError,
        );
      } finally {
        api.close();
      }
    },
  );

  testWidgets('non-admin account cannot see the admin Vault section', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance Vault quotas'), findsNothing);
      expect(find.text('Load Vaults'), findsNothing);
      expect(harness.api.listOffsets, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'admin can load, edit quota, refresh, and paginate Vault metadata',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      final pendingPage = Completer<AdminVaultPage>();
      harness.api.pendingList = pendingPage.future;
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Instance Vault quotas'), findsOneWidget);
        expect(
          find.textContaining('Encrypted names and contents are never shown.'),
          findsOneWidget,
        );

        await tester.ensureVisible(find.text('Load Vaults'));
        await tester.tap(find.text('Load Vaults'));
        await tester.pump();
        expect(find.text('Reading Vault list…'), findsOneWidget);
        pendingPage.complete(_page([_vault(_vaultId, quota: 4096)], offset: 0));
        await tester.pumpAndSettle();
        expect(find.text('alice@example.test'), findsOneWidget);
        expect(find.text(_vaultId), findsOneWidget);
        expect(find.text(_ownerId), findsOneWidget);
        expect(find.text('active'), findsOneWidget);
        expect(find.textContaining('4.0 KiB'), findsOneWidget);
        expect(find.text('SHOULD_NOT_RENDER_NAME'), findsNothing);
        expect(find.text('SHOULD_NOT_RENDER_CIPHERTEXT'), findsNothing);
        expect(harness.api.listOffsets, [0]);

        harness.api.pages.addAll([
          _page([_vault(_vaultId, quota: 8192)], offset: 0),
          _page([
            _vault(_secondVaultId, owner: 'dana@example.test'),
          ], offset: 50),
        ]);
        await tester.ensureVisible(find.text('Edit quota'));
        await tester.tap(find.text('Edit quota'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '8192');
        await tester.tap(find.text('Save quota'));
        await tester.pumpAndSettle();

        expect(harness.api.quotaWrites, [(_vaultId, 8192)]);
        expect(harness.api.listOffsets, [0, 0]);
        expect(find.textContaining('8.0 KiB'), findsOneWidget);
        expect(
          find.textContaining('quota updated to 8192 bytes'),
          findsOneWidget,
        );

        await tester.ensureVisible(find.text('Next'));
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(harness.api.listOffsets, [0, 0, 50]);
        expect(find.text('dana@example.test'), findsOneWidget);
        expect(find.text(_secondVaultId), findsOneWidget);
        expect(find.text('Previous'), findsOneWidget);
      } finally {
        if (!pendingPage.isCompleted) {
          pendingPage.completeError(StateError('test disposed'));
        }
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('Vault list and quota API failures remain visible with retry', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.listError = const ApiException(
      statusCode: 403,
      code: 'INSTANCE_ADMIN_REQUIRED',
      message: 'Admin access denied.',
    );
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load Vaults'));
      await tester.tap(find.text('Load Vaults'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load the Vault list:'), findsOneWidget);
      expect(find.textContaining('Admin access denied.'), findsOneWidget);

      harness.api.listError = null;
      harness.api.pages.add(_page([_vault(_vaultId, quota: 4096)], offset: 0));
      await tester.ensureVisible(find.text('Load Vaults'));
      await tester.tap(find.text('Load Vaults'));
      await tester.pumpAndSettle();
      harness.api.quotaError = const ApiException(
        statusCode: 403,
        code: 'INSTANCE_ADMIN_REQUIRED',
        message: 'Quota update denied.',
      );
      await tester.ensureVisible(find.text('Edit quota'));
      await tester.tap(find.text('Edit quota'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '8192');
      await tester.tap(find.text('Save quota'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t update the Vault quota:'), findsOneWidget);
      expect(find.textContaining('Quota update denied.'), findsOneWidget);
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
    await openSettingsCategory(tester, 'access', ifAvailable: true);
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

  static Future<_Harness> create(
    SodiumSumo sodium, {
    required bool isAdmin,
  }) async {
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
        baseUrl: 'https://admin-vaults-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final List<int> listOffsets = [];
  final List<AdminVaultPage> pages = [];
  final List<(String, int)> quotaWrites = [];
  Future<AdminVaultPage>? pendingList;
  ApiException? listError;
  ApiException? quotaError;

  @override
  Future<AdminVaultPage> adminVaults({int limit = 50, int offset = 0}) async {
    listOffsets.add(offset);
    if (listError case final error?) throw error;
    if (pendingList case final request?) {
      pendingList = null;
      return request;
    }
    if (pages.isEmpty) throw StateError('No fake Vault page configured');
    return pages.removeAt(0);
  }

  @override
  Future<AdminVaultQuotaReceipt> updateAdminVaultQuota({
    required String vaultId,
    required int quotaBytes,
  }) async {
    quotaWrites.add((vaultId, quotaBytes));
    if (quotaError case final error?) throw error;
    return AdminVaultQuotaReceipt(
      vaultId: vaultId,
      quotaBytes: quotaBytes,
      storedBytes: 1024,
      reservedUploadBytes: 256,
      updatedAt: DateTime.utc(2026, 9, 29, 14),
    );
  }
}

AdminVaultPage _page(List<AdminVaultMetadata> vaults, {required int offset}) =>
    AdminVaultPage(vaults: vaults, total: 51, limit: 50, offset: offset);

AdminVaultMetadata _vault(
  String vaultId, {
  int quota = 4096,
  String owner = 'alice@example.test',
}) => AdminVaultMetadata(
  vaultId: vaultId,
  ownerUserId: _ownerId,
  ownerUsername: owner,
  state: 'active',
  storedBytes: 2048,
  reservedUploadBytes: 512,
  quotaBytes: quota,
  createdAt: DateTime.utc(2026, 9, 1),
);

Map<String, dynamic> _vaultJson() => {
  'vault_id': _vaultId,
  'owner_user_id': _ownerId,
  'owner_username': 'alice@example.test',
  'state': 'active',
  'stored_bytes': 2048,
  'reserved_upload_bytes': 512,
  'quota_bytes': 4096,
  'created_at': '2026-09-01T00:00:00Z',
  'vault_name_ciphertext': 'SHOULD_NOT_RENDER_NAME',
  'ciphertext': 'SHOULD_NOT_RENDER_CIPHERTEXT',
};
