import 'dart:async';

import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('atermius/window_chrome');

Map<String, Object?> _state({Object? captionHeight, bool maximized = false}) => {
  'enabled': true,
  'maximized': maximized,
  'minimized': false,
  'focused': true,
  'captionHeight': ?captionHeight,
};

Future<void> _native(MethodCall call) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => done.complete(),
      );
  await done.future;
}

Widget _bar(WindowChromeController chrome, {double textScale = 1}) =>
    MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: WindowsWindowChrome(
          controller: chrome,
          navigationEmbedded: () => true,
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Column(
          children: [
            WorkspaceTabBar(
              tabs: const [
                WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
                WorkspaceTab(id: 'ssh', title: 'Производство · 本番'),
              ],
              selectedId: 'ssh',
              onSelect: (_) {},
              onClose: (_) {},
              onSearch: () {},
              onToggleTools: () {},
              actions: [
                IconButton(
                  key: const ValueKey('caller_action'),
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, Object?> nativeState;
  setUp(() {
    nativeState = _state(captionHeight: 31.0);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'enable' || call.method == 'getState') {
            return nativeState;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  test('native caption metric is parsed strictly and bounded', () {
    WindowChromeState? parse(Object? value) =>
        WindowChromeState.fromNative(_state(captionHeight: value));
    expect(parse(31.0)!.captionHeight, 31.0);
    expect(parse(30.666666)!.captionHeight, closeTo(30.67, .01));
    expect(parse(42)!.captionHeight, 42.0);
    // Missing (older runner) or implausible values are not trusted.
    expect(parse(null)!.captionHeight, isNull);
    for (final bad in [double.nan, double.infinity, 4.0, 400.0, '31', true]) {
      final state = parse(bad);
      expect(state, isNotNull, reason: '$bad must not drop the chrome state');
      expect(state!.captionHeight, isNull, reason: '$bad');
    }
    // Required booleans stay strict.
    expect(
      WindowChromeState.fromNative({'enabled': true, 'captionHeight': 31.0}),
      isNull,
    );
  });

  testWidgets(
    'single merged bar follows the native metric and its DPI/theme updates',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chrome = WindowChromeController(supported: true);
      addTearDown(chrome.dispose);
      await tester.pumpWidget(_bar(chrome));
      await tester.pumpAndSettle();

      final nav = find.byKey(const ValueKey('workspace_navigation_bar'));
      Rect rect(String key) => tester.getRect(find.byKey(ValueKey(key)));
      void expectAligned(double height) {
        expect(tester.takeException(), isNull);
        // One row only: no separate caption above the navigation.
        expect(
          find.byKey(const ValueKey('windows_window_caption')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('window_caption_minimize')),
          findsOneWidget,
        );
        expect(tester.getSize(nav).height, height);
        final bar = tester.getRect(nav);
        for (final key in [
          'window_caption_minimize',
          'window_caption_maximize',
          'window_caption_close',
        ]) {
          expect(rect(key).height, height, reason: key);
          expect(rect(key).top, bar.top, reason: key);
        }
        final center = bar.center.dy;
        for (final key in [
          'workspace-tab-hosts',
          'workspace-tab-ssh',
          'workspace_host_search_button',
          'workspace_terminal_sidebar_button',
          'caller_action',
        ]) {
          expect(rect(key).center.dy, closeTo(center, .01), reason: key);
          expect(rect(key).top, greaterThanOrEqualTo(bar.top), reason: key);
          expect(
            rect(key).bottom,
            lessThanOrEqualTo(bar.bottom),
            reason: key,
          );
        }
        expect(
          rect('workspace-tab-hosts').height,
          rect('workspace-tab-ssh').height,
        );
      }

      expectAligned(31);

      // WM_DPICHANGED / WM_SETTINGCHANGE / WM_THEMECHANGED re-send the state.
      await _native(
        MethodCall('stateChanged', _state(captionHeight: 36.0)),
      );
      await tester.pumpAndSettle();
      expectAligned(36);

      // Maximize keeps the same metric (no terminal row reflow).
      await _native(
        MethodCall(
          'stateChanged',
          _state(captionHeight: 36.0, maximized: true),
        ),
      );
      await tester.pumpAndSettle();
      expectAligned(36);
      expect(find.byTooltip('Restore'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('large text grows the bar instead of clipping the tab label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chrome = WindowChromeController(supported: true);
    addTearDown(chrome.dispose);
    await tester.pumpWidget(_bar(chrome, textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final metrics = WindowBarMetrics.native(31, const TextScaler.linear(2));
    expect(metrics.height, greaterThan(31));
    final bar = tester.getSize(
      find.byKey(const ValueKey('workspace_navigation_bar')),
    );
    expect(bar.height, metrics.height);
    final label = tester.getRect(find.text('Производство · 本番'));
    final tab = tester.getRect(
      find.byKey(const ValueKey('workspace-tab-ssh')),
    );
    expect(label.top, greaterThanOrEqualTo(tab.top));
    expect(label.bottom, lessThanOrEqualTo(tab.bottom));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'without a reported metric or custom chrome the bar keeps its fallbacks',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      nativeState = _state();
      final chrome = WindowChromeController(supported: true);
      addTearDown(chrome.dispose);
      await tester.pumpWidget(_bar(chrome));
      await tester.pumpAndSettle();
      final nav = find.byKey(const ValueKey('workspace_navigation_bar'));
      expect(
        tester.getSize(nav).height,
        WindowBarMetrics.fallbackCaptionHeight,
      );

      // Android/web/unsupported: unchanged 48 px touch bar, no caption keys.
      final touch = WindowChromeController(supported: false);
      addTearDown(touch.dispose);
      await tester.pumpWidget(_bar(touch));
      await tester.pumpAndSettle();
      expect(tester.getSize(nav).height, 48);
      expect(
        tester.getSize(find.byKey(const ValueKey('workspace-tab-ssh'))).height,
        32,
      );
      expect(find.byKey(const ValueKey('window_caption_minimize')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('standalone caption uses the same native metric', (
    tester,
  ) async {
    final chrome = WindowChromeController(supported: true);
    addTearDown(chrome.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) =>
            WindowsWindowChrome(controller: chrome, child: child!),
        home: const Scaffold(body: Text('Sign in')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('windows_window_caption')))
          .height,
      31,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('window_caption_close')))
          .height,
      31,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
