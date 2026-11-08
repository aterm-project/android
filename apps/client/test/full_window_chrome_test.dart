import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class _App extends AppController {
  _App({required super.sodium, required super.database})
    : super(secureStore: ClientSecureStore());
  @override
  Future<void> restoreLastServer() async {}
}

void main() {
  testWidgets(
    'complete startup has one Windows navigation and search beside minimize',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const channel = MethodChannel('atermius/window_chrome');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'enabled': true,
          'maximized': false,
          'minimized': false,
          'focused': true,
        },
      );
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _App(sodium: await SodiumSumoInit.init(), database: db)
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts
        ..activeVault = const VaultDescriptor(
          id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      try {
        await tester.pumpWidget(
          AtermiusStartup(initialize: () async => AtermiusApp(controller: app)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceTabBar), findsOneWidget);
        expect(
          find.byKey(const ValueKey('workspace_navigation_bar')),
          findsOneWidget,
        );
        expect(find.text('Hosts'), findsOneWidget);
        expect(find.text('Your server fleet'), findsNothing);
        expect(find.text('Add host'), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(FilterChip), findsNothing);
        expect(find.byKey(const ValueKey('cloud_add_group')), findsNothing);
        expect(
          find.byKey(const ValueKey('windows_window_caption')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('window_caption_minimize')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('window_caption_close')),
          findsOneWidget,
        );
        final search = tester.getRect(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        final minimize = tester.getRect(
          find.byKey(const ValueKey('window_caption_minimize')),
        );
        expect(search.right, minimize.left);
        expect(search.center.dy, minimize.center.dy);
        expect(find.byKey(const ValueKey('cloud_home_search')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(WorkspaceTabBar),
            matching: find.byType(TextField),
          ),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('host_search_palette')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('workspace_navigation_bar')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('windows_window_caption')),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('host_search_palette')), findsNothing);
        expect(find.byKey(const ValueKey('cloud_home_search')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(WorkspaceTabBar),
            matching: find.byType(TextField),
          ),
          findsNothing,
        );
        expect(find.byType(ChoiceChip), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
