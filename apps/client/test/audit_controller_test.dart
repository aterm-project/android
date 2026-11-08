import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'scope switching filters account/current Vault and restarts paging',
    () async {
      final api = _AuditApi()
        ..pages.addAll([
          AuditPage(
            events: [_accountEvent, _vaultEvent],
            nextCursor: 'cursor-2',
            hasMore: true,
          ),
          AuditPage(
            events: [_accountEvent, _vaultEvent],
            nextCursor: 'cursor-2',
            hasMore: true,
          ),
          AuditPage(events: [_vaultEvent], nextCursor: null, hasMore: false),
          AuditPage(
            events: [_accountEvent, _vaultEvent],
            nextCursor: 'cursor-2',
            hasMore: true,
          ),
        ]);
      final harness = _AuditHarness(sodium, api);
      try {
        await harness.app.loadAudit(reset: true);
        expect(harness.app.visibleAuditEvents.map((event) => event.scope), [
          'account',
        ]);
        expect(api.cursors, [null]);

        await harness.app.selectAuditScope(AuditScope.activeVault);
        expect(api.cursors, [null, null]);
        expect(harness.app.visibleAuditEvents.map((event) => event.vaultId), [
          _vaultId,
        ]);
        expect(harness.app.auditPageIndex, 0);
        expect(harness.app.auditHasMore, isTrue);

        await harness.app.nextAuditPage();
        expect(api.cursors.last, 'cursor-2');
        expect(harness.app.auditPageIndex, 1);
        expect(harness.app.auditHasMore, isFalse);
        await harness.app.previousAuditPage();
        expect(api.cursors.last, isNull);
        expect(harness.app.auditPageIndex, 0);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'empty state, API errors, and expired cursor can recover from page one',
    () async {
      final api = _AuditApi()
        ..pages.addAll([
          const AuditPage(events: [], nextCursor: null, hasMore: false),
          AuditPage(
            events: [_accountEvent],
            nextCursor: 'cursor-2',
            hasMore: true,
          ),
          const AuditPage(events: [], nextCursor: null, hasMore: false),
        ]);
      final harness = _AuditHarness(sodium, api);
      try {
        await harness.app.loadAudit();
        expect(harness.app.auditPageEvents, isEmpty);
        expect(harness.app.auditError, isNull);
        expect(harness.app.auditLoading, isFalse);

        await harness.app.refreshAudit();
        expect(harness.app.auditPageEvents, [_accountEvent]);
        expect(harness.app.auditHasMore, isTrue);

        api.errors.add(
          const ApiException(
            statusCode: 410,
            code: 'AUDIT_CURSOR_EXPIRED',
            message: 'Cursor expired',
          ),
        );
        await harness.app.nextAuditPage();
        expect(harness.app.auditError, contains('游标已过期'));

        await harness.app.refreshAudit();
        expect(harness.app.auditError, isNull);
        expect(harness.app.auditPageIndex, 0);
        expect(api.cursors.last, isNull);
        expect(harness.app.auditHasMore, isFalse);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'viewer cannot render vault audit rows even if a response includes one',
    () async {
      final api = _AuditApi()
        ..pages.add(
          AuditPage(events: [_vaultEvent], nextCursor: null, hasMore: false),
        );
      final harness = _AuditHarness(sodium, api);
      harness.app.activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'viewer',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      );
      try {
        await harness.app.selectAuditScope(AuditScope.activeVault);
        expect(harness.app.canReadActiveVaultAudit, isFalse);
        expect(harness.app.auditPageEvents, [_vaultEvent]);
        expect(harness.app.visibleAuditEvents, isEmpty);
      } finally {
        await harness.dispose();
      }
    },
  );
}

class _AuditHarness {
  _AuditHarness(this.sodium, this.api)
    : database = ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore = ClientSecureStore() {
    app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: secureStore,
          )
          ..api = api
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
  }

  final SodiumSumo sodium;
  final _AuditApi api;
  final ClientDatabase database;
  final ClientSecureStore secureStore;
  late final AppController app;

  Future<void> dispose() async {
    app.dispose();
    api.close();
    await database.close();
  }
}

class _AuditApi extends ApiClient {
  _AuditApi()
    : super(
        baseUrl: 'https://audit-controller.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final List<String?> cursors = [];
  final List<AuditPage> pages = [];
  final List<ApiException> errors = [];

  @override
  Future<AuditPage> audit({String? cursor, int limit = 100}) async {
    cursors.add(cursor);
    if (errors.isNotEmpty) throw errors.removeAt(0);
    if (pages.isEmpty) throw StateError('No fake audit page configured');
    return pages.removeAt(0);
  }
}

final _accountEvent = AuditEvent(
  eventId: '1',
  scope: 'account',
  vaultId: null,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: null,
  action: 'account.created',
  resourceType: 'account',
  resourceId: null,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27),
  source: 'api',
);

final _vaultEvent = AuditEvent(
  eventId: '2',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.key_rotated',
  resourceType: 'vault',
  resourceId: _vaultId,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12),
  source: 'api',
);
