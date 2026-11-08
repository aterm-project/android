import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_search_palette.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Host menu and search fit a single Windows row at narrow widths',
    (tester) async {
      const channel = MethodChannel('atermius/window_chrome');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return {
              'enabled': true,
              'maximized': false,
              'minimized': false,
              'focused': true,
              // GetSystemMetricsForDpi(SM_CYCAPTION + SM_CYSIZEFRAME +
              // SM_CXPADDEDBORDER) at 96 DPI on Windows 10/11.
              'captionHeight': 31.0,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final chrome = WindowChromeController(supported: true);
      await chrome.start();
      var opened = false;
      var searched = false;
      var toggled = false;
      for (final width in [390.0, 800.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: WindowChromeScope(
              controller: chrome,
              child: Scaffold(
                body: Column(
                  children: [
                    WorkspaceTabBar(
                      tabs: const [
                        WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
                        WorkspaceTab(id: 'ssh', title: 'Production SSH'),
                      ],
                      selectedId: 'ssh',
                      onSelect: (_) {},
                      onClose: (_) {},
                      onSearch: () => searched = true,
                      onToggleTools: () => toggled = true,
                      homeMenuActions: [
                        WorkspaceAction(
                          'open_settings',
                          'Settings',
                          Icons.settings_outlined,
                          () => opened = true,
                        ),
                      ],
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(
          find.byKey(const ValueKey('workspace_navigation_bar')),
        );
        expect(bar.height, 31);
        final home = tester.getRect(
          find.byKey(const ValueKey('workspace-tab-hosts')),
        );
        final session = tester.getRect(
          find.byKey(const ValueKey('workspace-tab-ssh')),
        );
        expect(home.height, 31 - 2 * 4);
        expect(home.height, session.height);
        expect(home.top, session.top);
        final search = tester.getRect(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        final controls = tester.getRect(
          find.byKey(const ValueKey('window_caption_minimize')),
        );
        expect(search.center.dy, controls.center.dy);
        final sidebar = tester.getRect(
          find.byKey(const ValueKey('workspace_terminal_sidebar_button')),
        );
        expect(search.right, sidebar.left);
        expect(sidebar.right, controls.left);
        expect(sidebar.center.dy, search.center.dy);
        expect(home.left - bar.left, 8);
        expect(home.top - bar.top, 4);
        await tester.tap(
          find.byKey(const ValueKey('workspace_terminal_sidebar_button')),
        );
        expect(toggled, isTrue);
        await tester.tap(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        expect(searched, isTrue);
        await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(opened, isTrue);
        expect(calls, isNot(contains('beginDrag')));
      }
      await tester.pumpWidget(const SizedBox());
      chrome.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('search closes on scope change and does not select stale hosts', (
    tester,
  ) async {
    final changes = ValueNotifier<int>(0);
    var current = true;
    HostSearchSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selection = await showHostSearchPalette(
                  context,
                  hosts: () => const [
                    HostRecord(
                      id: 'host',
                      name: 'Production',
                      address: 'example.test',
                      username: 'root',
                    ),
                  ],
                  groups: const {},
                  fieldKey: const ValueKey('search'),
                  isCurrent: () => current,
                  changes: changes,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host_search_palette')), findsOneWidget);
    current = false;
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host_search_palette')), findsNothing);
    expect(selection, isNull);
    expect(tester.takeException(), isNull);
    changes.dispose();
  });
}
