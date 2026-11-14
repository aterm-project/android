import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

/// "Restore connection" and recovery must use the Host as saved now, not the
/// revision the tab was first opened with (a mapping added since must
/// apply). These cover the callers: AppController and the view's button.

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

const _vault = VaultDescriptor(
  id: 'vault-reconnect',
  role: 'owner',
  activeKeyEpoch: 'epoch',
  membershipVersion: 'membership',
);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  useAppLocaleFixture('en');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppController reconnects a desktop tab with the Host saved after '
      'the first connect', () async {
    // VNC: this host has no bundled RDP engine, so only VNC tabs connect
    // directly here; the Host handling is the same for RDP.
    const v1 = HostRecord(
      id: 'desk',
      name: 'Desk',
      address: 'desk-v1.example',
      protocol: HostProtocol.vnc,
    );
    final v2 = v1.copyWith(address: 'desk-v2.example');
    final connected = <HostRecord>[];
    final connections = <_Connection>[];
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            desktopConnectionForTesting: (host) {
              connected.add(host);
              final c = _Connection();
              connections.add(c);
              return c;
            },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-reconnect',
            accessToken: 'access-reconnect',
            expiresIn: 3600,
            refreshToken: 'refresh-reconnect',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..activeVault = _vault
          ..hosts.add(v1);
    try {
      await app.openTerminalTab(v1);
      final tab = app.activeTerminalTab!;
      expect(connected.map((h) => h.address), [v1.address]);
      connections.single.controller.addError(StateError('Disconnected'));
      await _settle();
      expect(tab.desktop!.state, 'disconnected');

      // The Host is edited and saved while the tab is disconnected.
      app.hosts[app.hosts.indexWhere((h) => h.id == v1.id)] = v2;
      await app.reconnectTerminalTab(tab.id);
      expect(connected.map((h) => h.address), [v1.address, v2.address]);
      expect(tab.desktop!.state, 'connecting');

      // The view's button calls reconnect() without a Host; the session
      // asks the controller for the Host saved now.
      final v3 = v1.copyWith(address: 'desk-v3.example');
      app.hosts[app.hosts.indexWhere((h) => h.id == v1.id)] = v3;
      connections.last.controller.addError(StateError('Disconnected'));
      await _settle();
      expect(tab.desktop!.state, 'disconnected');
      await tab.desktop!.reconnect();
      expect(connected.map((h) => h.address), [
        v1.address,
        v2.address,
        v3.address,
      ]);
    } finally {
      await app.disconnectAllTerminalTabs();
      app.dispose();
      await database.close();
    }
  });

  testWidgets('Restore connection in the view lets the session resolve the '
      'Host saved now', (tester) async {
    final session = _RecordingSession()
      ..state = 'disconnected'
      ..error = 'Disconnected';
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DesktopView(session: session))),
    );
    final restore = find.byKey(const ValueKey('desktop_restore_connection'));
    expect(restore, findsOneWidget);
    await tester.tap(restore);
    await tester.pump();
    // No Host from the view: DesktopSession.reconnect then asks latestHost
    // (covered in desktop_reconnect_test.dart and the AppController test
    // above), never the revision the tab was first opened with.
    expect(session.reconnects, [null]);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
}

class _RecordingSession extends DesktopSession {
  final reconnects = <HostRecord?>[];
  @override
  bool get canReconnect => true;
  @override
  Future<void> reconnect({HostRecord? host}) async => reconnects.add(host);
}
