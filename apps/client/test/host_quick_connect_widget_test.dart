import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class QuickController extends AppController {
  QuickController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  HostRecord? connected;
  String? serialPort;
  @override
  Future<void> openTerminalTab(
    HostRecord host, {
    void Function(String tabId)? onTabOpened,
  }) async {
    connected = host;
  }

  @override
  Future<void> openConsoleTab({
    String? serialPort,
    int baudRate = 115200,
  }) async {
    this.serialPort = serialPort;
  }

  @override
  Future<void> saveHost(HostRecord host) async {
    hosts.add(host);
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'Home search filters and quick-connects while topbar palette stays available',
    (tester) async {
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          QuickController(
              sodium: await SodiumSumoInit.init(),
              database: db,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..activeVault = const VaultDescriptor(
              id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );
      const existing = HostRecord(
        id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        name: 'Production edge',
        address: 'edge.example.test',
        username: 'root',
        port: 22122,
      );
      app.hosts.addAll([
        existing,
        const HostRecord(
          id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          name: 'Staging',
          address: 'stage.example.test',
          username: 'root',
        ),
      ]);
      try {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final homeSearch = find.byKey(const ValueKey('cloud_home_search'));
        expect(homeSearch, findsOneWidget);
        await tester.enterText(homeSearch, 'Production');
        await tester.pump();
        expect(
          find.byKey(
            const ValueKey('host_connect_cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('host_connect_dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
          ),
          findsNothing,
        );
        await tester.enterText(
          homeSearch,
          'ssh root@edge.example.test -p 22122',
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(app.connected, same(existing));
        await tester.enterText(homeSearch, 'console tty @COM3');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(app.serialPort, 'COM3');
        const vnc = HostRecord(
          id: 'vnc-saved',
          name: 'Desktop',
          address: 'vnc.example.test',
          username: 'admin',
          port: 5901,
          protocol: HostProtocol.vnc,
        );
        app.hosts.add(vnc);
        await tester.enterText(
          homeSearch,
          'vnc admin@vnc.example.test -p 5901',
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(app.connected, same(vnc));
        await tester.enterText(homeSearch, '');
        await tester.pump();
        final search = find.byKey(const ValueKey('cloud_host_search'));
        expect(search, findsNothing);
        final trigger = find.byKey(
          const ValueKey('workspace_host_search_button'),
        );
        expect(tester.getRect(trigger).center.dy, lessThan(48));
        expect(
          find.byKey(const ValueKey('workspace_host_menu')),
          findsOneWidget,
        );
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final palette = find.byKey(const ValueKey('host_search_palette'));
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('host_search_filters')))
              .dy,
          greaterThan(tester.getBottomLeft(search).dy),
        );
        await tester.enterText(search, 'Production');
        await tester.pump();
        expect(
          find.descendant(of: palette, matching: find.text('Production edge')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: palette, matching: find.text('Staging')),
          findsNothing,
        );
        await tester.enterText(search, 'ssh root@edge.example.test -p 22122');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(app.connected, same(existing));
        expect(palette, findsNothing);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        await tester.enterText(search, 'console tty @COM3');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(app.serialPort, 'COM3');
        await tester.enterText(
          homeSearch,
          'rdp admin@new.example.test -p 3390',
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        TextField field(String label) => tester.widget<TextField>(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label,
          ),
        );
        expect(field('Hostname or IP').controller!.text, 'new.example.test');
        expect(field('Port').controller!.text, '3390');
        expect(find.text('Save and connect'), findsOneWidget);
        final password = find.byKey(const ValueKey('host_editor_password'));
        await tester.ensureVisible(password);
        await tester.enterText(password, 'fixture-password');
        await tester.tap(find.text('Save and connect'));
        await tester.pumpAndSettle();
        expect(app.connected?.address, 'new.example.test');
        expect(app.connected?.protocol, HostProtocol.rdp);
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
        await db.close();
      }
    },
  );
}
