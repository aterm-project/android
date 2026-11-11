import 'dart:async';

import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const channel = MethodChannel('atermius/window_chrome');
Map<String, Object?> state({bool maximized = false}) => {
  'enabled': true,
  'maximized': maximized,
  'minimized': false,
  'focused': true,
};
Future<void> native(MethodCall call) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'enable' || call.method == 'getState') {
            return state();
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets(
    'caption controls invoke own-window commands and follow native maximize state',
    (tester) async {
      final controller = WindowChromeController(supported: true);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsWindowChrome(
            controller: controller,
            child: const Scaffold(body: Text('Workspace')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final command in ['minimize', 'maximize', 'close']) {
        await tester.tap(find.byKey(ValueKey('window_caption_$command')));
        await tester.pump();
      }
      expect(calls.map((c) => c.method), [
        'enable',
        'minimize',
        'toggleMaximize',
        'close',
      ]);
      expect(calls.every((c) => c.arguments == null), isTrue);
      await native(MethodCall('stateChanged', state(maximized: true)));
      await tester.pump();
      expect(find.byTooltip('Restore'), findsOneWidget);
      expect(find.byTooltip('Maximize'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  testWidgets('caption above Navigator supports drag and rounded window menu', (
    tester,
  ) async {
    final controller = WindowChromeController(supported: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) =>
            WindowsWindowChrome(controller: controller, child: child!),
        home: const Scaffold(),
      ),
    );
    await tester.pumpAndSettle();
    final area = find.byKey(const ValueKey('window_caption_drag_area'));
    await tester.drag(area, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'beginDrag'), hasLength(1));
    final point = tester.getCenter(area);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'toggleMaximize'), hasLength(1));
    await tester.tapAt(point, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Minimize'), findsOneWidget);
    final menuMaterial = tester
        .widgetList<Material>(find.byType(Material))
        .where((m) => m.shape is RoundedRectangleBorder)
        .last;
    expect(
      (menuMaterial.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(12),
    );
    await tester.tap(find.text('Minimize'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'minimize'), hasLength(1));
    expect(calls.where((c) => c.method == 'showSystemMenu'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
    'navigation owns the sole controls and preserves content across frame changes',
    (tester) async {
      final controller = WindowChromeController(supported: true);
      final embedded = ValueNotifier<bool>(true);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => WindowsWindowChrome(
            controller: controller,
            navigationState: embedded,
            navigationEmbedded: () => embedded.value,
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: embedded,
                  builder: (_, enabled, _) => enabled
                      ? WorkspaceTabBar(
                          tabs: const [
                            WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
                          ],
                          selectedId: 'home',
                          onSelect: (_) {},
                          onClose: (_) {},
                          actions: [
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.more_horiz),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                const TextField(key: ValueKey('retained_input')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nav = find.byKey(const ValueKey('workspace_navigation_bar'));
      final minimize = find.byKey(const ValueKey('window_caption_minimize'));
      expect(
        find.byKey(const ValueKey('windows_window_caption')),
        findsNothing,
      );
      expect(minimize, findsOneWidget);
      expect(tester.getCenter(minimize).dy, tester.getCenter(nav).dy);
      // Runner without a metric: the documented fallback, not the old 48.
      expect(
        tester.getSize(nav).height,
        WindowBarMetrics.fallbackCaptionHeight,
      );
      expect(find.text('Atermius'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('retained_input')),
        'keep typed value',
      );
      embedded.value = false;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows_window_caption')),
        findsOneWidget,
      );
      expect(minimize, findsOneWidget);
      expect(find.text('keep typed value'), findsOneWidget);
      embedded.value = true;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows_window_caption')),
        findsNothing,
      );
      expect(find.text('keep typed value'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(360, 480));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(minimize).right, lessThanOrEqualTo(360));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      embedded.dispose();
      controller.dispose();
    },
  );
  test('close guard handshakes, deduplicates requests and preserves a hidden engine', () async {
    final controller = WindowChromeController(supported: true);
    final entered = Completer<void>();
    final leave = Completer<void>();
    var requests = 0;
    await controller.setCloseGuard(() async {
      requests++;
      entered.complete();
      await leave.future;
      await controller.hide();
    });
    expect(calls.last.method, 'enableCloseGuard');
    expect(calls.last.arguments, {'enabled': true});
    final first = native(const MethodCall('closeRequested'));
    await entered.future;
    await native(const MethodCall('closeRequested'));
    expect(requests, 1);
    leave.complete();
    await first;
    expect(calls.last.method, 'hide');
    await controller.show();
    await controller.closeNow();
    expect(
      calls.map((c) => c.method),
      containsAllInOrder(['hide', 'show', 'closeNow']),
    );
    await controller.setCloseGuard(null);
    expect(calls.last.arguments, {'enabled': false});
    controller.dispose();
  });
  testWidgets(
    'unsupported and missing native runners retain their original child',
    (tester) async {
      final unsupported = WindowChromeController(supported: false);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsWindowChrome(
            controller: unsupported,
            child: const Text('Original'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Original'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('windows_window_caption')),
        findsNothing,
      );
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      unsupported.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw MissingPluginException(),
          );
      final missing = WindowChromeController(supported: true);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsWindowChrome(
            controller: missing,
            child: const Text('Fallback'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fallback'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('windows_window_caption')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      missing.dispose();
    },
  );
  test('malformed native state cannot change window state', () async {
    final controller = WindowChromeController(supported: true);
    await controller.start();
    var changes = 0;
    controller.addListener(() => changes++);
    await native(MethodCall('stateChanged', state()));
    expect(changes, 0);
    await native(
      const MethodCall('stateChanged', {
        'enabled': true,
        'maximized': 'invalid',
      }),
    );
    expect(controller.state.enabled, isTrue);
    expect(controller.state.maximized, isFalse);
    controller.dispose();
  });
  test(
    'failed close guard preserves engine and dispose disables delegation',
    () async {
      final controller = WindowChromeController(supported: true);
      await controller.setCloseGuard(
        () async => throw StateError('cleanup failed'),
      );
      await native(const MethodCall('closeRequested'));
      expect(calls.any((c) => c.method == 'closeNow'), isFalse);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'enableCloseGuard');
      expect(calls.last.arguments, {'enabled': false});
    },
  );
}
