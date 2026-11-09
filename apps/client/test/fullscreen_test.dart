import 'dart:async';

import 'package:aterm_client/platform/fullscreen.dart';
import 'package:aterm_client/platform/fullscreen_native.dart' as native;
import 'package:aterm_client/ui/fullscreen_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    FullscreenController.debugInstance = null;
    debugDefaultTargetPlatformOverride = null;
  });
  test('discovers a window that is already in native fullscreen', () async {
    final controller = FullscreenController(
      supported: true,
      changes: const Stream.empty(),
      read: () async => true,
      apply: (value) async => value,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.enabled, isTrue);
    controller.dispose();
  });
  test(
    'toggle serializes pending native transition and reports actual state',
    () async {
      final completion = Completer<bool>();
      final requests = <bool>[];
      final controller = FullscreenController(
        supported: true,
        changes: const Stream.empty(),
        apply: (value) {
          requests.add(value);
          return completion.future;
        },
      );
      final first = controller.toggle();
      expect(controller.busy, isTrue);
      expect(await controller.toggle(), isFalse);
      expect(requests, [true]);
      completion.complete(true);
      expect(await first, isTrue);
      expect(controller.enabled, isTrue);
      expect(controller.busy, isFalse);
      controller.dispose();
    },
  );
  test(
    'failed entry never claims fullscreen and platform exit updates state',
    () async {
      final changes = StreamController<bool>(sync: true);
      final controller = FullscreenController(
        supported: true,
        changes: changes.stream,
        apply: (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await controller.toggle(), isFalse);
      expect(controller.enabled, isFalse);
      changes.add(true);
      expect(controller.enabled, isTrue);
      changes.add(false);
      expect(controller.enabled, isFalse);
      controller.dispose();
      await changes.close();
    },
  );
  test(
    'late refresh cannot overwrite a completed fullscreen transition',
    () async {
      final read = Completer<bool?>();
      final controller = FullscreenController(
        supported: true,
        changes: const Stream.empty(),
        read: () => read.future,
        apply: (value) async => value,
      );
      final refresh = controller.refresh();
      expect(await controller.toggle(), isTrue);
      read.complete(false);
      await refresh;
      expect(controller.enabled, isTrue);
      controller.dispose();
    },
  );
  testWidgets('tools menu enters and exits fullscreen with accurate labels', (
    tester,
  ) async {
    final requests = <bool>[];
    final controller = FullscreenController(
      supported: true,
      changes: const Stream.empty(),
      read: () async => requests.isEmpty ? false : requests.last,
      apply: (value) async {
        requests.add(value);
        return value;
      },
    );
    FullscreenController.debugInstance = controller;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FullscreenToolsMenu())),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter fullscreen'));
    await tester.pumpAndSettle();
    expect(requests, [true]);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exit fullscreen'));
    await tester.pumpAndSettle();
    expect(requests, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  test('Android uses own-window insets bridge instead of ignored SystemChrome mode', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    const channel = MethodChannel('atermius/fullscreen');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'set'
              ? (call.arguments as Map)['enabled']
              : false;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(await native.applyFullscreen(true), isTrue);
    expect(await native.applyFullscreen(false), isFalse);
    expect(calls.map((e) => e.method), ['set', 'set']);
    expect(calls.first.arguments, {'enabled': true});
  });
  test(
    'iOS uses supported manual overlays for both entry and restoration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      expect(await native.applyFullscreen(true), isTrue);
      expect(await native.applyFullscreen(false), isFalse);
      expect(calls.map((e) => e.method), [
        'SystemChrome.setEnabledSystemUIOverlays',
        'SystemChrome.setEnabledSystemUIOverlays',
      ]);
      expect(calls.first.arguments, isEmpty);
      expect(calls.last.arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
    },
  );
  test(
    'Windows covers current monitor then uncovers saved placement',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const channel = MethodChannel('atermius/window_geometry');
      bool covering = false;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            const bounds = {'x': 2000, 'y': 200, 'width': 800, 'height': 600};
            switch (call.method) {
              case 'getBounds':
                return {
                  'bounds': bounds,
                  'normal': bounds,
                  'covering': covering,
                  'maximized': false,
                  'minimized': false,
                };
              case 'getMonitors':
                return [
                  {
                    'bounds': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
                    'primary': true,
                  },
                  {
                    'bounds': {
                      'x': 1920,
                      'y': 0,
                      'width': 1920,
                      'height': 1080,
                    },
                    'primary': false,
                  },
                ];
              case 'coverMonitor':
                covering = true;
                return true;
              case 'uncover':
                covering = false;
                return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await native.applyFullscreen(true), isTrue);
      expect(calls.firstWhere((e) => e.method == 'coverMonitor').arguments, {
        'x': 1920,
        'y': 0,
        'width': 1920,
        'height': 1080,
      });
      expect(await native.applyFullscreen(false), isFalse);
      expect(calls.any((e) => e.method == 'uncover'), isTrue);
    },
  );
}
