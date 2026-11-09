import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_shell.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/home_add_sharing_row.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _self = '11111111-1111-4111-8111-111111111111';
const _alice = '22222222-2222-4222-8222-222222222222';
const _bob = '33333333-3333-4333-8333-333333333333';
const _carol = '44444444-4444-4444-8444-444444444444';
const _vaultId = '55555555-5555-4555-8555-555555555555';
const _otherVaultId = '66666666-6666-4666-8666-666666666666';
const _device = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Map<String, dynamic> _member(
  String id,
  String name, {
  String role = 'editor',
  String state = 'active',
}) => {'user_id': id, 'username': name, 'role': role, 'state': state};

final _now = DateTime.utc(2026, 11, 8, 12);

void main() {
  group('HomeSharingSnapshot.fromVault', () {
    HomeSharingSnapshot project({
      List<Map<String, dynamic>>? members,
      List<VaultPresenceDevice> devices = const [],
      DateTime? fetchedAt,
      bool failed = false,
    }) => HomeSharingSnapshot.fromVault(
      members:
          members ??
          [
            _member(_self, 'me@example.test', role: 'owner'),
            _member(_alice, 'alice.smith@example.test'),
            _member(_bob, 'bob@example.test', role: 'viewer'),
            _member(_carol, 'carol@example.test', state: 'revoked'),
          ],
      devices: devices,
      selfUserId: _self,
      selfUsername: 'me@example.test',
      presenceFetchedAt: fetchedAt,
      presenceFailed: failed,
      now: _now,
    );

    test('members not loaded shows only the signed-in user', () {
      final s = project(members: const []);
      expect(s.mode, HomeSharingMode.notLoaded);
      expect(s.people.map((p) => p.userId), [_self]);
      expect(s.people.single.isSelf, isTrue);
    });

    test(
      'a single active member is individual, invitations are not shared',
      () {
        final s = project(
          members: [
            _member(_self, 'me@example.test', role: 'owner'),
            _member(_alice, 'alice@example.test', state: 'invited'),
          ],
          fetchedAt: _now,
        );
        expect(s.mode, HomeSharingMode.individual);
        expect(s.people.last.invited, isTrue);
      },
    );

    test('fresh lease is online, fresh snapshot without lease is offline', () {
      final s = project(
        fetchedAt: _now.subtract(const Duration(seconds: 10)),
        devices: [
          VaultPresenceDevice(
            userId: _alice,
            deviceId: _device,
            lastSeenAt: _now.subtract(const Duration(seconds: 20)),
          ),
        ],
      );
      expect(s.mode, HomeSharingMode.shared);
      expect(s.activeCount, 3, reason: 'revoked members are excluded');
      expect(s.people.any((p) => p.userId == _carol), isFalse);
      final byId = {for (final p in s.people) p.userId: p};
      expect(byId[_self]!.presence, HomeSharingPresence.online);
      expect(byId[_alice]!.presence, HomeSharingPresence.online);
      expect(byId[_bob]!.presence, HomeSharingPresence.offline);
      expect(s.onlineOthers, 1);
      expect(byId[_alice]!.initials, 'AS');
      expect(s.people.first.isSelf, isTrue);
    });

    test('expired leases and stale snapshots become unknown, never online', () {
      final s = project(
        fetchedAt: _now.subtract(const Duration(minutes: 5)),
        devices: [
          VaultPresenceDevice(
            userId: _alice,
            deviceId: _device,
            lastSeenAt: _now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );
      final byId = {for (final p in s.people) p.userId: p};
      expect(byId[_alice]!.presence, HomeSharingPresence.unknown);
      expect(byId[_bob]!.presence, HomeSharingPresence.unknown);
      expect(s.onlineOthers, 0);
    });

    test('presence error or no fetch is unknown', () {
      for (final s in [project(failed: true, fetchedAt: _now), project()]) {
        expect(s.presenceKnown, isFalse);
        expect(
          s.people.where((p) => !p.isSelf).map((p) => p.presence).toSet(),
          {HomeSharingPresence.unknown},
        );
      }
    });
  });

  group('HomeAddSharingRow', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required Widget row,
      double width = 390,
    }) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: row),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final added = <HostProtocol>[];
    final shells = <LocalShellLaunch>[];
    final serial = <QuickConnectRequest>[];
    setUp(() {
      added.clear();
      shells.clear();
      serial.clear();
    });

    HomeAddSharingRow row({
      bool shell = true,
      bool serialOk = true,
      bool canAdd = true,
      HomeSharingSnapshot snapshot = const HomeSharingSnapshot.local(),
      VoidCallback? onDetails,
    }) => HomeAddSharingRow(
      idPrefix: 'test',
      canAddHosts: canAdd,
      onAddHost: added.add,
      onLaunchShell: shells.add,
      onSerialConsole: serial.add,
      shellSupportedOverride: shell,
      serialSupportedOverride: serialOk,
      sharing: HomeSharingCluster(
        idPrefix: 'test',
        snapshot: snapshot,
        onOpenDetails: onDetails ?? () {},
      ),
    );

    Future<void> choose(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('test_home_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pumpAndSettle();
    }

    testWidgets('390px: Add menu lists every protocol and routes each', (
      tester,
    ) async {
      await pumpRow(tester, row: row());
      expect(tester.takeException(), isNull);
      final addBox = tester.getRect(
        find.byKey(const ValueKey('test_home_add')),
      );
      expect(addBox.height, greaterThanOrEqualTo(40));
      expect(addBox.right, lessThanOrEqualTo(390));
      await tester.tap(find.byKey(const ValueKey('test_home_add')));
      await tester.pumpAndSettle();
      for (final id in [
        'ssh',
        'telnet',
        'rdp',
        'vnc',
        'shell',
        'shell_options',
        'console',
      ]) {
        expect(find.byKey(ValueKey('test_home_add_$id')), findsOneWidget);
      }
      expect(find.text('New Telnet host'), findsOneWidget);
      expect(find.text('Shell (system default)'), findsOneWidget);
      expect(find.text('Serial Console (COM)…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 690));
      await tester.pumpAndSettle();

      for (final protocol in [
        HostProtocol.ssh,
        HostProtocol.telnet,
        HostProtocol.rdp,
        HostProtocol.vnc,
      ]) {
        await choose(tester, 'test_home_add_${protocol.name}');
      }
      expect(added, [
        HostProtocol.ssh,
        HostProtocol.telnet,
        HostProtocol.rdp,
        HostProtocol.vnc,
      ]);
      await choose(tester, 'test_home_add_shell');
      expect(shells, [LocalShellLaunch.systemDefault]);
      expect(serial, isEmpty, reason: 'Shell never opens a serial Console');
    });

    testWidgets('read-only Vault disables Host entries but keeps Shell', (
      tester,
    ) async {
      await pumpRow(tester, row: row(canAdd: false));
      await choose(tester, 'test_home_add_ssh');
      expect(added, isEmpty);
      await tester.tapAt(const Offset(5, 690));
      await tester.pumpAndSettle();
      await choose(tester, 'test_home_add_shell');
      expect(shells, hasLength(1));
    });

    testWidgets('Console validates COM port and baud through quick connect', (
      tester,
    ) async {
      await pumpRow(tester, row: row());
      await choose(tester, 'test_home_add_console');
      expect(
        find.byKey(const ValueKey('home_serial_console_dialog')),
        findsOne,
      );
      await tester.enterText(
        find.byKey(const ValueKey('home_serial_console_port')),
        'ttyS0',
      );
      await tester.tap(find.byKey(const ValueKey('home_serial_console_open')));
      await tester.pumpAndSettle();
      expect(serial, isEmpty);
      expect(
        find.byKey(const ValueKey('home_serial_console_dialog')),
        findsOne,
      );
      await tester.enterText(
        find.byKey(const ValueKey('home_serial_console_port')),
        'com3',
      );
      await tester.enterText(
        find.byKey(const ValueKey('home_serial_console_baud')),
        '9600',
      );
      await tester.tap(find.byKey(const ValueKey('home_serial_console_open')));
      await tester.pumpAndSettle();
      expect(serial.single.kind, QuickConnectKind.serial);
      expect(serial.single.address, 'COM3');
      expect(serial.single.baudRate, 9600);
      expect(shells, isEmpty);
    });

    testWidgets('unsupported Shell/serial show the existing explanations', (
      tester,
    ) async {
      await pumpRow(tester, row: row(shell: false, serialOk: false));
      await choose(tester, 'test_home_add_shell_unavailable');
      expect(
        find.byKey(const ValueKey('local_shell_unavailable_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await choose(tester, 'test_home_add_console');
      expect(
        find.byKey(const ValueKey('home_serial_console_unavailable_dialog')),
        findsOneWidget,
      );
      expect(
        find.text('The COM serial Console requires the Windows client.'),
        findsOneWidget,
      );
      expect(shells, isEmpty);
      expect(serial, isEmpty);
    });

    testWidgets('local indicator is Local only and opens read-only detail', (
      tester,
    ) async {
      await pumpRow(
        tester,
        row: HomeAddSharingRow(
          idPrefix: 'test',
          onAddHost: added.add,
          onLaunchShell: shells.add,
          onSerialConsole: serial.add,
          sharing: Builder(
            builder: (context) => HomeSharingCluster(
              idPrefix: 'test',
              snapshot: const HomeSharingSnapshot.local(),
              onOpenDetails: () => showHomeLocalSharingDetails(context),
            ),
          ),
        ),
      );
      expect(find.text('Local only'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('test_home_sharing_local_avatar')),
        findsOneWidget,
      );
      expect(find.textContaining('Shared'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('test_home_sharing')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home_local_sharing_dialog')),
        findsOneWidget,
      );
    });

    testWidgets('390px shared cluster wraps, overflows to +N with tooltips', (
      tester,
    ) async {
      final members = [
        _member(_self, 'me@example.test', role: 'owner'),
        for (var i = 0; i < 6; i++)
          _member(
            '7777777$i-7777-4777-8777-777777777777',
            'user$i@example.test',
          ),
      ];
      final snapshot = HomeSharingSnapshot.fromVault(
        members: members,
        devices: [
          VaultPresenceDevice(
            userId: '77777770-7777-4777-8777-777777777777',
            deviceId: _device,
            lastSeenAt: DateTime.now().toUtc(),
          ),
        ],
        selfUserId: _self,
        selfUsername: 'me@example.test',
        presenceFetchedAt: DateTime.now().toUtc(),
        presenceFailed: false,
        now: DateTime.now().toUtc(),
      );
      await pumpRow(tester, row: row(snapshot: snapshot));
      expect(tester.takeException(), isNull);
      expect(find.text('Shared · 7 members · 1 online'), findsOneWidget);
      final overflow = find.byKey(const ValueKey('test_home_sharing_overflow'));
      expect(
        find.descendant(of: overflow, matching: find.text('+5')),
        findsOne,
      );
      final self = find.byKey(
        const ValueKey('test_home_sharing_avatar_$_self'),
      );
      expect(
        tester
            .widget<Tooltip>(
              find.descendant(of: self, matching: find.byType(Tooltip)),
            )
            .message,
        'me@example.test (you) · OWNER · Online on this device',
      );
      final sharing = tester.getRect(
        find.byKey(const ValueKey('test_home_sharing')),
      );
      expect(sharing.right, lessThanOrEqualTo(390 - 16 + 0.1));
      // Wide: sharing stays on the same line, aligned right.
      await pumpRow(tester, row: row(snapshot: snapshot), width: 1100);
      final addRect = tester.getRect(
        find.byKey(const ValueKey('test_home_add')),
      );
      final wide = tester.getRect(
        find.byKey(const ValueKey('test_home_sharing')),
      );
      expect((wide.center.dy - addRect.center.dy).abs(), lessThan(4));
      expect(wide.right, closeTo(1100 - 16, 1));
    });
  });

  group('cloud Home integration', () {
    testWidgets(
      'row sits below search; Telnet opens prefilled editor; scope guarded',
      (tester) async {
        final db = ClientDatabase.forTesting(NativeDatabase.memory());
        final app = _HomeController(
          sodium: await SodiumSumoInit.init(),
          database: db,
          secureStore: ClientSecureStore(),
        );
        try {
          await tester.binding.setSurfaceSize(const Size(390, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(),
              home: AppShell(controller: app),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final search = find.byKey(const ValueKey('cloud_home_search'));
          final add = find.byKey(const ValueKey('cloud_home_add'));
          expect(add, findsOneWidget);
          expect(
            tester.getTopLeft(add).dy,
            greaterThan(tester.getBottomLeft(search).dy),
          );
          // Members are loaded once through the existing authenticated API.
          expect(app.memberRefreshCount, 1);
          expect(find.text('Shared · 2 members · 1 online'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('cloud_home_sharing_avatar_$_alice')),
            findsOneWidget,
          );

          Future<void> openTelnetEditor() async {
            await tester.tap(add);
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('cloud_home_add_telnet')),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<DropdownButtonFormField<HostProtocol>>(
                    find.byKey(const ValueKey('host_editor_protocol')),
                  )
                  .initialValue,
              HostProtocol.telnet,
            );
            await tester.enterText(
              find.byKey(const ValueKey('host_editor_name')),
              'Switch',
            );
            await tester.enterText(
              find.byKey(const ValueKey('host_editor_address')),
              'switch.example.test',
            );
          }

          await openTelnetEditor();
          await tester.tap(find.byKey(const ValueKey('host_editor_save')));
          await tester.pumpAndSettle();
          expect(app.saved.single.protocol, HostProtocol.telnet);
          expect(app.saved.single.port, 23);

          // Same Vault/account IDs but a different server session object:
          // the open editor belongs to the earlier scope and must not save.
          await openTelnetEditor();
          app.api = _offlineApi('https://home-b.test');
          await tester.tap(find.byKey(const ValueKey('host_editor_save')));
          await tester.pumpAndSettle();
          expect(app.saved, hasLength(1));
          expect(app.currentVaultId, _vaultId);

          // Same IDs after a Vault A->B->A reselection (new generation).
          await openTelnetEditor();
          app.selectionGeneration++;
          await tester.tap(find.byKey(const ValueKey('host_editor_save')));
          await tester.pumpAndSettle();
          expect(app.saved, hasLength(1));
          expect(app.currentVaultId, _vaultId);

          // Unchanged scope still saves (the guard is not a blanket block).
          await openTelnetEditor();
          await tester.tap(find.byKey(const ValueKey('host_editor_save')));
          await tester.pumpAndSettle();
          expect(app.saved, hasLength(2));

          // A Vault switch while the editor is open must not save there.
          await openTelnetEditor();
          app.activeVault = const VaultDescriptor(
            id: _otherVaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
          await tester.tap(find.byKey(const ValueKey('host_editor_save')));
          await tester.pumpAndSettle();
          expect(app.saved, hasLength(2));

          // Sharing details reuse the existing Vault members dialog.
          app.activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'viewer',
            activeKeyEpoch: '1',
            membershipVersion: '1',
            canWrite: false,
          );
          app.notifyListeners();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('cloud_home_sharing')));
          await tester.pumpAndSettle();
          expect(find.text('Members · Home Vault'), findsOneWidget);
          expect(find.text('Revoke access'), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
          await db.close();
        }
      },
    );

    testWidgets('unauthenticated Home fetches nothing and shows no others', (
      tester,
    ) async {
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _HomeController(
        sodium: await SodiumSumoInit.init(),
        database: db,
        secureStore: ClientSecureStore(),
        signedIn: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: CloudHomeSharingStatus(app: app, onOpenDetails: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.memberRefreshCount, 0);
        expect(app.presenceRefreshCount, 0);
        expect(find.text('Members not loaded'), findsOneWidget);
        expect(find.textContaining('Shared'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await db.close();
      }
    });
  });
}

class _HomeController extends AppController {
  _HomeController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    this.signedIn = true,
  }) {
    stage = ClientStage.workspace;
    page = WorkspacePage.hosts;
    activeVault = const VaultDescriptor(
      id: _vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
    );
    api = _offlineApi('https://home-a.test');
  }

  final bool signedIn;
  int selectionGeneration = 0;

  @override
  int get vaultSelectionGeneration => selectionGeneration;
  int memberRefreshCount = 0;
  int presenceRefreshCount = 0;
  final saved = <HostRecord>[];

  @override
  bool get authenticated => signedIn;

  @override
  String? get currentAccountId => signedIn ? _self : null;

  @override
  String? get authenticatedUsername => signedIn ? 'me@example.test' : null;

  @override
  String get currentVaultName => 'Home Vault';

  @override
  Future<void> refreshVaultMembers({String? vaultId}) async {
    memberRefreshCount++;
    vaultMembers = [
      _member(_self, 'me@example.test', role: 'owner'),
      _member(_alice, 'alice@example.test'),
    ];
    vaultPresenceDevices = [
      VaultPresenceDevice(
        userId: _alice,
        deviceId: _device,
        lastSeenAt: DateTime.now().toUtc(),
      ),
    ];
    notifyListeners();
  }

  @override
  Future<void> refreshVaultPresenceList({String? vaultId}) async {
    presenceRefreshCount++;
  }

  @override
  Future<void> saveHost(HostRecord host) async {
    saved.add(host);
    hosts.add(host);
    notifyListeners();
  }
}

/// Never reaches the network: every request fails locally.
ApiClient _offlineApi(String baseUrl) => ApiClient(
  baseUrl: baseUrl,
  client: MockClient((_) async => http.Response('', 503)),
);
